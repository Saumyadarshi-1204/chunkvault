# HTTP API

Public endpoints are served by the Drogon API server. Storage-node endpoints are internal.

## API server

| Method | Path | Auth | Success | Purpose |
| --- | --- | --- | --- | --- |
| GET | `/health` | None | 200 `{"status":"ok"}` | Process liveness |
| POST | `/auth/login` | None | 200 access JWT + refresh | Email and password |
| POST | `/auth/refresh` | Refresh token | 200 new pair | Rotate refresh; revoke family on reuse |
| POST | `/auth/logout` | Refresh token | 204 | Delete hashed refresh in Redis |
| POST | `/files` | user, admin | 201 | Create file; body is chunked at 4 MiB |
| GET | `/files` | user, admin | 200 | List files the caller may see |
| GET | `/files/{id}` | owner or admin | 200 | Metadata; bytes via chunk assembly |
| GET | `/files/{id}/content` | owner or admin | 200 | Reassembled file |
| DELETE | `/files/{id}` | owner or admin | 204 | Soft delete |
| GET | `/admin/nodes` | admin | 200 | Registry plus heartbeat-derived liveness |
| POST | `/admin/nodes/{id}/enabled` | admin | 204 | Enable or disable a node |
| POST | `/admin/gc` | admin | 202 | Run chunk GC for deleted files |

Access token: `Authorization: Bearer <jwt>`, 15-minute expiry, claims `sub`, `role`, `exp`, `iss`.

Error codes: 400 malformed input or chunk larger than 4 MiB; 401 missing or expired token; 403 wrong role or not owner; 404 unknown file; 409 hash mismatch or file not complete; 503 fewer live nodes than `replication_factor`.

## Storage nodes (A, B, C)

| Method | Path | Success | Purpose |
| --- | --- | --- | --- |
| PUT | `/chunks/{id}` | 201 or 200 if already present with same hash | Store at most 4 MiB; `{id}` must be SHA-256 of the body |
| GET | `/chunks/{id}` | 200 raw bytes | Read chunk |
| DELETE | `/chunks/{id}` | 204 | Remove bytes |
| GET | `/health` | 200 | Process and data directory |

`{id}` is 64 lowercase hex characters. PUT with a mismatched hash returns 409. PUT over 4 MiB returns 400. Callers are the API server only.
