# Sequence diagrams

Flows below match [SDD.md](../design/SDD.md) and [schema.md](../design/schema.md). The API server is the only public participant. Storage nodes never see user JWTs. Refresh-token hashes and node status are stored in PostgreSQL; Redis remains a cache and short TTL heartbeat aid.

## 1. Registration and login

Register inserts a `users` row and issues the same token pair as login. Login looks up `lower(email)`, verifies Argon2id, and starts a new refresh `family_id`. The access JWT lasts 15 minutes and is not stored. Only SHA-256 of the refresh token is written to `refresh_tokens`.

```mermaid
sequenceDiagram
  autonumber
  actor Client
  participant API as API server
  participant PG as PostgreSQL

  Client->>API: POST /auth/register email password
  API->>API: Hash password Argon2id
  API->>PG: INSERT users role user
  alt email already registered
    PG-->>API: unique violation
    API-->>Client: 409
  else new account
    API->>API: Sign JWT 15m and random refresh
    API->>PG: INSERT refresh_tokens hash family_id
    API-->>Client: 201 access_token refresh_token

    Client->>API: POST /auth/login email password
    API->>PG: SELECT users by lower email
    API->>API: Verify Argon2id
    alt bad credentials
      API-->>Client: 401
    else ok
      API->>API: Sign JWT 15m and random refresh
      API->>PG: INSERT refresh_tokens new family_id
      API-->>Client: 200 access_token refresh_token
    end
  end
```

## 2. Access token refresh

A valid refresh token is hashed and matched to a live `refresh_tokens` row. The API revokes that row, inserts a new hash in the same `family_id`, and returns a new JWT plus refresh token. If the presented hash belongs to a family but is already revoked, the API revokes every row in that family (reuse detection) and returns 401.

```mermaid
sequenceDiagram
  autonumber
  actor Client
  participant API as API server
  participant PG as PostgreSQL

  Client->>API: POST /auth/refresh refresh_token
  API->>API: SHA-256 of raw token
  API->>PG: SELECT refresh_tokens by token_hash
  alt no row or expired
    API-->>Client: 401
  else row revoked_at set reuse of old token
    API->>PG: SET revoked_at on all rows with family_id
    API-->>Client: 401 family revoked
  else live row
    API->>PG: SET revoked_at on current row
    API->>API: Sign JWT 15m and new refresh
    API->>PG: INSERT refresh_tokens same family_id new hash
    API-->>Client: 200 access_token refresh_token
  end
```

## 3. File upload

The API splits the body into 4 MiB slices (last slice may be shorter), sets each chunk id to SHA-256 of those bytes, and looks up `chunks`. If `ref_count` is already positive and two `ok` replicas exist, it only increments `ref_count`. Otherwise it PUTs the bytes to two live nodes, then commits `files`, `file_versions`, `file_version_chunks`, and `chunk_replicas`. If one node PUT fails, the router retries a third live node; if two writes still cannot succeed, it compensating-deletes any new unreferenced bytes and returns 503 without setting `current_version_id`.

```mermaid
sequenceDiagram
  autonumber
  actor Client
  participant API as API server
  participant PG as PostgreSQL
  participant NodeA as Storage node A
  participant NodeB as Storage node B
  participant NodeC as Storage node C

  Client->>API: POST /files multipart Bearer JWT
  API->>API: Authorize owner of parent_id
  API->>API: Split 4 MiB slices and SHA-256 each
  loop each chunk
    API->>PG: SELECT chunks id and ok replica count
    alt chunk exists and ok replicas meet factor
      API->>PG: increment ref_count
    else new or under-replicated
      API->>PG: SELECT two online nodes by heartbeat
      API->>NodeA: PUT /chunks/id body
      NodeA->>NodeA: Verify SHA-256 and size
      NodeA-->>API: 201
      API->>NodeB: PUT /chunks/id body
      alt NodeB succeeds
        NodeB-->>API: 201
      else NodeB fails
        NodeB-->>API: error
        API->>NodeC: PUT /chunks/id body
        alt NodeC succeeds
          NodeC-->>API: 201
        else still short of factor
          API->>NodeA: DELETE /chunks/id if unreferenced
          API-->>Client: 503
        end
      end
    end
  end
  API->>PG: INSERT files file_versions file_version_chunks chunk_replicas
  API->>PG: SET files.current_version_id
  API-->>Client: 201 FileMetadata
```

## 4. File download

The API loads the file, `current_version_id`, ordered `file_version_chunks`, and `ok` replica rows, skipping nodes whose heartbeat or `status` is down. For each chunk it GETs one replica, recomputes SHA-256, and appends the bytes. A failed GET or hash mismatch marks that replica `missing` and retries another live replica. After all slices verify, the API returns the concatenated body; if no intact replica remains for a slice, it returns 410 or 503.

```mermaid
sequenceDiagram
  autonumber
  actor Client
  participant API as API server
  participant PG as PostgreSQL
  participant NodeA as Storage node A
  participant NodeB as Storage node B

  Client->>API: GET /files/id/content Bearer JWT
  API->>PG: SELECT files current_version file_version_chunks chunk_replicas
  API->>API: Skip offline nodes
  loop each ordinal
    API->>NodeA: GET /chunks/id
    alt 200 and SHA-256 matches id
      NodeA-->>API: bytes
    else fail or hash mismatch
      NodeA-->>API: error or bad hash
      API->>PG: SET chunk_replicas status missing
      API->>NodeB: GET /chunks/id
      alt NodeB verifies
        NodeB-->>API: bytes
      else no intact replica
        API-->>Client: 410 or 503
      end
    end
  end
  API->>API: Concatenate slices in ordinal order
  API-->>Client: 200 application/octet-stream
```

## 5. Node failure and re-replication

When node A misses its heartbeat TTL, the API sets `nodes.status` to `offline` and excludes it from placement. It then selects chunks whose `ok` replica count is below `replication_factor`, reads a surviving replica, PUTs the bytes to another online node, and inserts a new `ok` `chunk_replicas` row. Chunks with no remaining `ok` replica cannot be repaired and stay lost until an operator restores disk.

```mermaid
sequenceDiagram
  autonumber
  participant NodeA as Storage node A
  participant API as API server
  participant PG as PostgreSQL
  participant NodeB as Storage node B
  participant NodeC as Storage node C

  NodeA--xAPI: heartbeat TTL expired
  API->>PG: UPDATE nodes status offline
  API->>PG: SELECT chunks with ok replica count below factor
  loop each under-replicated chunk
    API->>PG: Pick source replica on a live node
    API->>NodeB: GET /chunks/id
    NodeB-->>API: bytes
    API->>API: Verify SHA-256
    API->>NodeC: PUT /chunks/id
    NodeC-->>API: 201
    API->>PG: INSERT chunk_replicas NodeC ok
    API->>PG: SET NodeA replica missing
  end
```

## 6. Share link access

The path token is hashed and looked up in `shares.token`. The API rejects missing, `revoked_at` set, or `expires_at` in the past (410). Public shares (`is_public`) need no JWT. Private shares require a bearer user who is the owner, an admin, or a row in `share_permissions`. On success the API returns file metadata; content download uses the same checks then the download replica path.

```mermaid
sequenceDiagram
  autonumber
  actor Client
  participant API as API server
  participant PG as PostgreSQL

  Client->>API: GET /shares/token/rawToken
  API->>API: SHA-256 of raw token
  API->>PG: SELECT shares files by token
  alt no row
    API-->>Client: 404
  else revoked_at or expires_at past
    API-->>Client: 410
  else is_public
    API-->>Client: 200 ShareAccess
  else not public
    API->>API: Require Bearer JWT
    API->>PG: owner admin or share_permissions
    alt no grant
      API-->>Client: 401 or 403
    else permitted
      API-->>Client: 200 ShareAccess
    end
  end
```
