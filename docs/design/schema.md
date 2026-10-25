# Metadata schema

PostgreSQL is the system of record for identity, the folder tree, file versions, chunk catalogs, replica placement, and share grants. Chunk payloads are not stored here.

Redis may still cache file metadata, replica location lists, and short heartbeat TTLs. `refresh_tokens.token_hash` and `nodes.last_heartbeat` are authoritative in PostgreSQL so restart of Redis cannot revive a revoked refresh token or hide a dead node.

## Entity-relationship diagram

```mermaid
erDiagram
  users ||--o{ refresh_tokens : issues
  users ||--o{ files : owns
  users ||--o{ file_versions : authors
  users ||--o{ shares : creates
  users ||--o{ share_permissions : granted
  files ||--o{ files : parent
  files ||--o{ file_versions : versions
  files ||--o{ shares : shared
  file_versions ||--o{ file_version_chunks : ordered
  chunks ||--o{ file_version_chunks : referenced
  chunks ||--o{ chunk_replicas : placed
  nodes ||--o{ chunk_replicas : stores
  shares ||--o{ share_permissions : grants

  users {
    uuid id PK
    text email UK
    text password_hash
    text role
    timestamptz created_at
    timestamptz updated_at
  }

  refresh_tokens {
    uuid id PK
    uuid user_id FK
    char token_hash UK
    uuid family_id
    timestamptz expires_at
    timestamptz revoked_at
    timestamptz created_at
  }

  nodes {
    uuid id PK
    text name UK
    text base_url
    text status
    timestamptz last_heartbeat
    bigint capacity_bytes
    bigint used_bytes
    timestamptz created_at
  }

  files {
    uuid id PK
    uuid owner_id FK
    uuid parent_id FK
    uuid current_version_id FK
    text name
    boolean is_folder
    text mime_type
    bigint size
    timestamptz deleted_at
    timestamptz created_at
    timestamptz updated_at
  }

  file_versions {
    uuid id PK
    uuid file_id FK
    int version_number
    bigint size
    char content_sha256
    uuid created_by FK
    timestamptz created_at
  }

  chunks {
    char id PK
    int size
    int ref_count
    timestamptz created_at
  }

  file_version_chunks {
    uuid version_id PK_FK
    int ordinal PK
    char chunk_id FK
    int size
  }

  chunk_replicas {
    char chunk_id PK_FK
    uuid node_id PK_FK
    text status
    timestamptz updated_at
  }

  shares {
    uuid id PK
    char token UK
    uuid file_id FK
    uuid created_by FK
    text access_level
    timestamptz expires_at
    boolean is_public
    timestamptz revoked_at
    timestamptz created_at
  }

  share_permissions {
    uuid share_id PK_FK
    uuid user_id PK_FK
    text access_level
    timestamptz created_at
  }
```

## `users`

Account records for `user` and `admin` roles. Login, register, and JWT `sub` / `role` claims read this table.

| Column | Type | Constraints |
| --- | --- | --- |
| `id` | UUID | Primary key. Stable subject for tokens and FKs. |
| `email` | TEXT | Not null. Unique on `lower(email)` so register/login are case-insensitive. |
| `password_hash` | TEXT | Not null. Argon2id; never store plaintext. |
| `role` | TEXT | Not null, `user` or `admin`. Checked so admin routes cannot be granted by a free-form string. |
| `created_at` | TIMESTAMPTZ | Not null. |
| `updated_at` | TIMESTAMPTZ | Not null. Touched on password or role change. |

**Keys and indexes**

- PK `id`: JWT `sub`, file ownership, share grants.
- Unique index `users_email_lower_uidx` on `lower(email)`: one account per mailbox; login lookup.
- Check `users_role_chk`: closed role set.

## `refresh_tokens`

Rotating refresh tokens. The raw token is shown once to the client; only `token_hash` is stored.

| Column | Type | Constraints |
| --- | --- | --- |
| `id` | UUID | Primary key. |
| `user_id` | UUID | Not null, FK `users(id)` ON DELETE CASCADE. Logout-all and account delete drop rows. |
| `token_hash` | CHAR(64) | Not null, unique, SHA-256 hex of the raw token. |
| `family_id` | UUID | Not null. All rotations of one login share a family. |
| `expires_at` | TIMESTAMPTZ | Not null. |
| `revoked_at` | TIMESTAMPTZ | Null while valid. Set on logout, rotation, or reuse detection. |
| `created_at` | TIMESTAMPTZ | Not null. |

**Keys and indexes**

- Unique `token_hash`: O(1) refresh and logout.
- Index `(user_id, family_id)`: revoke the whole family when a prior hash is presented.
- Index `expires_at` where `revoked_at IS NULL`: purge job.
- Check `token_hash ~ '^[0-9a-f]{64}$'`.

Reuse of a revoked hash in an otherwise live family revokes every row with that `family_id`.

## `nodes`

Storage-node registry. Placement and admin health read this table. Heartbeats update `last_heartbeat` and `status`.

| Column | Type | Constraints |
| --- | --- | --- |
| `id` | UUID | Primary key. |
| `name` | TEXT | Not null, unique. Operator label (`A`, `B`, `C`). |
| `base_url` | TEXT | Not null, unique. Internal PUT/GET/DELETE base. |
| `status` | TEXT | Not null: `online`, `offline`, `draining`, `disabled`. |
| `last_heartbeat` | TIMESTAMPTZ | Not null. Stale values mean the router must not place new replicas. |
| `capacity_bytes` | BIGINT | Not null, `>= 0`. Placement hint. |
| `used_bytes` | BIGINT | Not null, `>= 0`, `<= capacity_bytes`. |
| `created_at` | TIMESTAMPTZ | Not null. |

**Keys and indexes**

- PK `id`: `chunk_replicas.node_id`.
- Unique `name`, unique `base_url`: prevent double registration.
- Index `status`: candidate set for replication factor 2.
- Index `last_heartbeat`: health listing ordered by recency.
- Checks on `status` and byte ranges.

## `files`

Files and folders in one tree. Folders have `is_folder = true` and no versions. Files have `current_version_id` once an upload completes.

| Column | Type | Constraints |
| --- | --- | --- |
| `id` | UUID | Primary key. |
| `owner_id` | UUID | Not null, FK `users(id)`. Authorization root for non-share access. |
| `parent_id` | UUID | FK `files(id)`. Null is the owner's root. |
| `name` | TEXT | Not null. Single path segment; no `/` or empty string. |
| `is_folder` | BOOLEAN | Not null. |
| `mime_type` | TEXT | Null for folders. |
| `size` | BIGINT | Not null, `>= 0`. Denormalized from the current version for list/metadata. Folders are 0. |
| `current_version_id` | UUID | FK `file_versions(id)`, deferrable. Null for folders and incomplete uploads. |
| `deleted_at` | TIMESTAMPTZ | Null when live. Soft delete; GC walks this. |
| `created_at` | TIMESTAMPTZ | Not null. |
| `updated_at` | TIMESTAMPTZ | Not null. Rename, move, metadata, new version. |

**Keys and indexes**

- PK `id`.
- Index `(owner_id, parent_id)` where `deleted_at IS NULL`: list folder contents.
- Unique `(owner_id, lower(name))` where `deleted_at IS NULL AND parent_id IS NULL`: one live name per owner at root.
- Unique `(parent_id, lower(name))` where `deleted_at IS NULL AND parent_id IS NOT NULL`: one live name per parent.
- Index `deleted_at` where not null: GC and trash scans.
- Check `parent_id IS DISTINCT FROM id`: no self-parent.
- Check `char_length(name) BETWEEN 1 AND 255` and `name !~ '[/\\]'`.
- Check `(is_folder AND current_version_id IS NULL AND mime_type IS NULL) OR (NOT is_folder)`.
- Trigger: `parent_id` must be a live folder with the same `owner_id`.

Soft delete does not remove rows. Child rows keep `parent_id` so a deleted folder can be walked for cascade-delete in the application.

## `file_versions`

Immutable versions of a non-folder file. Rollback either points `files.current_version_id` at an older row or inserts a new row that copies that version's chunk list.

| Column | Type | Constraints |
| --- | --- | --- |
| `id` | UUID | Primary key. |
| `file_id` | UUID | Not null, FK `files(id)` ON DELETE RESTRICT. |
| `version_number` | INTEGER | Not null, `>= 1`. |
| `size` | BIGINT | Not null, `>= 0`. Sum of slice sizes. |
| `content_sha256` | CHAR(64) | Null until all slices are committed. Whole-file hash of concatenated chunk bytes. |
| `created_by` | UUID | Not null, FK `users(id)`. Owner or a share with `write`. |
| `created_at` | TIMESTAMPTZ | Not null. |

**Keys and indexes**

- Unique `(file_id, version_number)`: list and compare by number.
- Index `file_id`: version history.
- Check on `content_sha256` format when not null.

## `chunks`

Content-addressed slices. `id` is SHA-256 of the bytes. `ref_count` is the number of `file_version_chunks` rows that point here.

| Column | Type | Constraints |
| --- | --- | --- |
| `id` | CHAR(64) | Primary key, lowercase SHA-256 hex. |
| `size` | INTEGER | Not null, `1`..`4194304` (4 MiB). Empty files have no chunk rows. |
| `ref_count` | INTEGER | Not null, `>= 0`. GC deletes storage-node bytes at 0. |
| `created_at` | TIMESTAMPTZ | Not null. |

**Keys and indexes**

- PK `id`: storage-node path `/chunks/{id}` and replica FK.
- Index `ref_count` where `ref_count = 0`: GC candidates.
- Check hex format and size bounds.

Inserting a `file_version_chunks` row must increment `ref_count` in the same transaction. Removing a version (or GCing a deleted file's versions) decrements it.

## `file_version_chunks`

Ordered chunk list for one version. Ordinal 0 is the first 4 MiB slice.

| Column | Type | Constraints |
| --- | --- | --- |
| `version_id` | UUID | FK `file_versions(id)` ON DELETE CASCADE, part of PK. |
| `ordinal` | INTEGER | `>= 0`, part of PK. Dense from 0 in the application. |
| `chunk_id` | CHAR(64) | Not null, FK `chunks(id)`. |
| `size` | INTEGER | Not null, `1`..`4194304`, matches `chunks.size` for that id. |

**Keys and indexes**

- PK `(version_id, ordinal)`: download assembly and version compare.
- Index `chunk_id`: find versions holding a chunk before decrementing `ref_count`.

## `chunk_replicas`

Which node holds a copy of a chunk, and whether that copy is usable.

| Column | Type | Constraints |
| --- | --- | --- |
| `chunk_id` | CHAR(64) | FK `chunks(id)` ON DELETE CASCADE, part of PK. |
| `node_id` | UUID | FK `nodes(id)`, part of PK. |
| `status` | TEXT | Not null: `writing`, `ok`, `missing`. |
| `updated_at` | TIMESTAMPTZ | Not null. |

**Keys and indexes**

- PK `(chunk_id, node_id)`: at most one replica row per node per chunk.
- Index `(node_id, status)`: drain or repair when a node fails.
- Index `(chunk_id)` where `status = 'ok'`: read placement; count vs replication factor.

A chunk is complete when `count(status = 'ok') >= replication_factor`.

## `shares`

Capability to a file or folder. The client holds the raw token; `token` stores SHA-256 hex of that value.

| Column | Type | Constraints |
| --- | --- | --- |
| `id` | UUID | Primary key. Revoke by id. |
| `token` | CHAR(64) | Not null, unique. Hash of the secret; access-by-token hashes the path parameter then looks up this column. |
| `file_id` | UUID | Not null, FK `files(id)`. Applies to that node of the tree; folder shares cover descendants in the application. |
| `created_by` | UUID | Not null, FK `users(id)`. Must be owner or admin at create time. |
| `access_level` | TEXT | Not null: `read` or `write`. |
| `expires_at` | TIMESTAMPTZ | Null means no expiry. |
| `is_public` | BOOLEAN | Not null. True: anyone presenting the token. False: token plus a `share_permissions` row (or the owner). |
| `revoked_at` | TIMESTAMPTZ | Null while active. |
| `created_at` | TIMESTAMPTZ | Not null. |

**Keys and indexes**

- Unique `token`: access by token.
- Index `file_id`: list shares for a file; revoke-all on delete.
- Index `(expires_at)` where `revoked_at IS NULL`: expiry sweeps.
- Check `access_level` in (`read`, `write`) and token hex format.

## `share_permissions`

Grants a specific user access to a non-public share (and optional per-user level).

| Column | Type | Constraints |
| --- | --- | --- |
| `share_id` | UUID | FK `shares(id)` ON DELETE CASCADE, part of PK. |
| `user_id` | UUID | FK `users(id)` ON DELETE CASCADE, part of PK. |
| `access_level` | TEXT | Not null: `read` or `write`. Must not exceed `shares.access_level` (enforced in the API). |
| `created_at` | TIMESTAMPTZ | Not null. |

**Keys and indexes**

- PK `(share_id, user_id)`: one grant per user per share.
- Index `user_id`: “shared with me”.
- Check `access_level` in (`read`, `write`).

## Constraints the application still owns

- Replication factor is configuration, not a table. The API counts `chunk_replicas` with `status = ok`.
- Cascade soft-delete of folder descendants.
- Folder share implies descendant access.
- `ref_count` increment/decrement is transactional with `file_version_chunks` changes.
- `files.current_version_id` is set only after replica writes succeed.
