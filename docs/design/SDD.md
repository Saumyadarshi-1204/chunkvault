# Software design document

## Purpose and scope

This document specifies how chunkvault stores, locates, replicates, and deletes file data. It covers the Drogon API server, PostgreSQL metadata, Redis auxiliary state, three storage-node processes, authentication, and failure handling.

Out of scope for this revision: client SDKs, multi-region clusters, billing, and a public object-storage compatibility layer (S3).

Related documents: [architecture](../architecture/architecture.md), [HTTP API](../api/http.md), [schema](schema.md), [decisions](decisions.md).

## Goals and non-goals

Goals:

- Durability of file bytes at a configurable replication factor (default 2) across storage nodes A, B, and C.
- Integrity: every stored chunk is addressable only by the SHA-256 of its bytes.
- A small, explicit metadata model in PostgreSQL, with soft delete of files and GC of unreferenced chunks.
- Role-separated access (`user`, `admin`) using short-lived JWTs and rotating hashed refresh tokens.
- Independent scaling and restart of storage nodes without moving metadata.

Non-goals:

- Content-defined chunking, encryption at rest inside the storage node, or erasure coding in this revision.
- Storage nodes that coordinate with each other or that serve end-user HTTP.
- Using Redis as the file catalog or as a blob store.
- Cross-cluster WAN replication.

## Architecture overview

Clients send HTTPS requests to the API layer. A router inside that process dispatches to Drogon controllers and selects storage nodes. The API server writes metadata to PostgreSQL and uses Redis for refresh-token hashes, node heartbeat TTLs, and caches. Payload bytes go only to storage nodes via `PUT/GET/DELETE /chunks/{id}`.

Placement: for a new chunk, the router picks two healthy nodes (or `replication_factor` when configured) that do not already hold that ID, writes both, then commits replica rows in PostgreSQL. Reads try a cached replica list, then PostgreSQL, then any node still marked live in Redis.

See [architecture.md](../architecture/architecture.md) for the component diagram and responsibility boundaries.

## Component design

**API server.** Layers: controllers (`api`), domain services (`services`), PostgreSQL access (`repositories`), models. Services own chunking, SHA-256, replica fan-out, reference counts, and GC. Controllers own HTTP status codes and request validation. The process reads listen address, port, thread count, database, Redis, JWT, and replication settings from the environment.

**Router.** Same binary. Node selection uses Redis heartbeats plus PostgreSQL registry. Write path requires `replication_factor` successful PUTs before the file is marked complete. Read path prefers the lowest-latency live replica.

**PostgreSQL.** System of record. See [schema.md](schema.md).

**Redis.** Key classes: `refresh:<sha256>` (user id, token family, expiry), `heartbeat:<node_id>` (capacity, timestamp, TTL), `cache:file:<file_id>`, `cache:locations:<chunk_id>`. Cache entries are invalidated on mutation.

**Storage nodes A/B/C.** Local disk (or volume) keyed by chunk ID. Auth to the node is a shared service credential from the API, not a user JWT. Health is `GET /health` plus a periodic heartbeat POST or SET from the node or from an API scrape; the liveness key lives in Redis.

## Data model

Normative column-level schema: [schema.md](schema.md).

Logical entities:

| Entity | Key | Notes |
| --- | --- | --- |
| `users` | `id` | Email, password hash, role `user` or `admin`. |
| `files` | `id` | Owner, name, byte size, optional whole-file SHA-256, status `active` or `deleted`, `deleted_at`. |
| `file_chunks` | `(file_id, ordinal)` | `chunk_id`, size of this slice (last slice may be under 4 MiB). |
| `chunks` | `id` (SHA-256 hex) | Size, `refcount`, created_at. |
| `chunk_replicas` | `(chunk_id, node_id)` | Status `writing`, `ok`, `missing`. |
| `storage_nodes` | `id` | Base URL, `enabled` flag. Liveness is not stored here. |

Dedup: inserting a file that produces an existing `chunk_id` increments `refcount` and does not rewrite bytes if `replication_factor` healthy replicas already exist.

Soft delete sets `files.status = deleted` and does not drop `file_chunks` until GC. GC decrements `chunks.refcount` per distinct chunk of that file; at 0 it DELETEs replicas on nodes, then deletes `chunk_replicas` and `chunks`.

## API design

Public HTTP contract: [http.md](../api/http.md).

Public surface (API server):

- `GET /health` — liveness, no auth.
- `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout`.
- `POST /files`, `GET /files`, `GET /files/{id}`, `DELETE /files/{id}` (soft delete). Upload may be a single body (API chunks internally) or chunk-at-a-time; both must produce the same 4 MiB slices and IDs.
- Admin: list nodes, enable/disable a node, trigger GC.

Storage node surface (not public):

- `PUT /chunks/{id}` — body ≤ 4 MiB; `{id}` must equal SHA-256 of the body (lowercase hex).
- `GET /chunks/{id}` — 200 with bytes, 404 if absent.
- `DELETE /chunks/{id}` — 204 if removed or already absent.
- `GET /health` — 200 if the process can read and write its data directory.

Errors use explicit HTTP codes: 400 validation, 401/403 authz, 404 missing, 409 incomplete or hash mismatch on PUT, 503 insufficient live nodes to meet replication factor.

## Chunking and integrity

Chunk size is fixed at 4 MiB (4 × 1024 × 1024 bytes). A file is split into consecutive slices of that size; the final slice may be shorter. Empty files store no chunks.

Chunk ID is SHA-256 of the slice bytes, encoded as 64 lowercase hex characters. The API computes the ID before PUT. The storage node recomputes SHA-256 on PUT and rejects a mismatch. GET responses may carry `X-Chunk-SHA256` for the caller to verify.

The API never trusts a client-supplied chunk ID without hashing the bytes it received.

## Replication and failure handling

Default `replication_factor` is 2, read from configuration, and must be ≤ number of enabled live nodes (three in the baseline deploy). New chunks are written to that many distinct nodes; PostgreSQL records each replica only after that node returns success for PUT.

If a PUT to one target fails, the router selects another live node that does not already hold the chunk. If fewer than `replication_factor` writes succeed, the API does not mark the file complete, issues compensating DELETEs for any partial new chunks that are unreferenced, and returns 503.

Heartbeat TTL expiry removes a node from the candidate set. Under-replicated `chunk_replicas` (ok count below the factor) are repaired by copying from a healthy replica to a replacement node. If no replica remains, the chunk is lost; the file GET fails with 410 or 503 depending on whether metadata still exists.

Reads: try replicas in heartbeat-fresh order. Hash mismatch on GET is treated as a bad replica: mark `missing`, read another replica, and schedule repair.

## Security design

**Auth.** Password login (hash stored on `users`) returns a JWT access token (15 minutes, issuer from config, claims: `sub`, `role`, `exp`) and a refresh token (cryptographically random, 256-bit). Refresh tokens rotate: each use issues a new token and stores only its hash in Redis under the same family id; reuse of a previous hash in that family revokes the family. Logout deletes the Redis hash. Roles: `user` (own files), `admin` (nodes, GC, any file metadata).

**Hashing.** File bytes: SHA-256 as described above. Passwords: a slow hash (Argon2id). Refresh tokens: SHA-256 (or HMAC-SHA256 with the JWT secret) of the raw token; Redis never stores the raw value. Access tokens are not stored.

**Token handling.** Access JWT is sent as `Authorization: Bearer`. The API validates signature, `exp`, and `iss`. Refresh is an HTTP-only cookie or a request body field on `/auth/refresh` only. Storage nodes do not accept user JWTs.

**Input validation.** Reject chunk bodies larger than 4 MiB, IDs that are not 64 hex chars, empty names, path traversal in file names, and role values other than `user`/`admin`. Bind PostgreSQL through parameterized queries. Size and content-length must match. Admin routes require `role=admin`.

## Deployment view

Baseline processes: one API server, one PostgreSQL, one Redis, storage nodes A, B, and C on separate hosts or containers. The API is the only ingress. Storage nodes bind an internal network. All endpoints, replica factor, JWT issuer, and credentials come from environment variables or a config file; nothing secret is compiled in.

Restart of a storage node is safe if its disk is intact: it resumes heartbeats and serves GET/PUT. Restart of the API is safe; in-flight uploads must be retried by the client. PostgreSQL is backed up independently of blob volumes; restoring metadata without the matching disks yields unreadable files.

## Observability

Structured logs (spdlog) on the API and storage nodes: request id, user id when authenticated, chunk id, node id, latency, HTTP status. No token or password material in logs.

`GET /health` on the API checks process liveness; a separate ready check should fail when PostgreSQL is down or live nodes &lt; `replication_factor`. Storage-node `/health` checks the data directory.

Log under-replication, hash mismatches, refresh-family reuse, and GC deletions of chunks. Redis heartbeat keys are the operational view of node liveness.

## Testing strategy

Every behavior change ships GoogleTest coverage under `tests/`. Unit tests cover chunk slicing (including a short last slice), SHA-256 IDs, replica selection, refcount increment/decrement, and JWT role checks.

Controller tests assert HTTP codes for `/health`, auth failure, oversize PUT, and hash mismatch. Repository tests use a test database or a transactional fixture. Redis-dependent token rotation is tested with a fake or isolated Redis.

Integration tests (CTest labels) start API plus one or more storage nodes against PostgreSQL and Redis, upload a file larger than 4 MiB, kill one node, and still GET the file. GC tests soft-delete then assert DELETE reached nodes when refcount hits zero, and that a shared chunk used by a second file is not deleted.

## Risks

- **GC vs. concurrent upload.** Decrementing refcount while another file is inserting the same chunk can drop live data. GC and insert must serialize on the `chunks` row.
- **Partial replica commit.** Bytes on a node without a PostgreSQL replica row become unreclaimable orphans unless a sweep compares node listings to `chunk_replicas`.
- **Replication factor vs. live nodes.** Three nodes and factor 2 tolerate one failure; a second failure loses chunks that had replicas only on the two dead nodes.
- **Refresh-token reuse detection.** A stolen token used once rotates the family and locks the legitimate client out; that is intended but will generate support load.
- **Fixed 4 MiB chunks.** Small-file workloads waste little space (last chunk is short) but gain no CDC dedup across similar files.

## Future improvements

- Content-defined chunking for cross-file dedup.
- Erasure coding as an alternative to n-way replication.
- Encryption at rest on the storage node, with keys outside PostgreSQL.
- Multi-region replica placement and rack-aware routing.
- Metrics and tracing exporters; admin audit log table.
- Online compaction and orphan-chunk sweep against node inventories.
