-- chunkvault metadata schema. Matches docs/design/schema.md.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT users_role_chk CHECK (role IN ('user', 'admin'))
);

CREATE UNIQUE INDEX users_email_lower_uidx ON users (lower(email));

CREATE TABLE refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token_hash CHAR(64) NOT NULL,
    family_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT refresh_tokens_hash_chk CHECK (token_hash ~ '^[0-9a-f]{64}$')
);

CREATE UNIQUE INDEX refresh_tokens_token_hash_uidx ON refresh_tokens (token_hash);
CREATE INDEX refresh_tokens_family_idx ON refresh_tokens (user_id, family_id);
CREATE INDEX refresh_tokens_expires_idx
    ON refresh_tokens (expires_at)
    WHERE revoked_at IS NULL;

CREATE TABLE nodes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    base_url TEXT NOT NULL,
    status TEXT NOT NULL,
    last_heartbeat TIMESTAMPTZ NOT NULL DEFAULT now(),
    capacity_bytes BIGINT NOT NULL DEFAULT 0,
    used_bytes BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT nodes_name_uk UNIQUE (name),
    CONSTRAINT nodes_base_url_uk UNIQUE (base_url),
    CONSTRAINT nodes_status_chk CHECK (
        status IN ('online', 'offline', 'draining', 'disabled')
    ),
    CONSTRAINT nodes_capacity_chk CHECK (capacity_bytes >= 0),
    CONSTRAINT nodes_used_chk CHECK (
        used_bytes >= 0 AND used_bytes <= capacity_bytes
    )
);

CREATE INDEX nodes_status_idx ON nodes (status);
CREATE INDEX nodes_last_heartbeat_idx ON nodes (last_heartbeat DESC);

CREATE TABLE files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES users (id),
    parent_id UUID REFERENCES files (id),
    current_version_id UUID,
    name TEXT NOT NULL,
    is_folder BOOLEAN NOT NULL DEFAULT FALSE,
    mime_type TEXT,
    size BIGINT NOT NULL DEFAULT 0,
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT files_parent_not_self_chk CHECK (parent_id IS DISTINCT FROM id),
    CONSTRAINT files_name_chk CHECK (
        char_length(name) BETWEEN 1 AND 255 AND name !~ '[/\\]'
    ),
    CONSTRAINT files_size_chk CHECK (size >= 0),
    CONSTRAINT files_folder_chk CHECK (
        (is_folder AND current_version_id IS NULL AND mime_type IS NULL)
        OR (NOT is_folder)
    )
);

CREATE INDEX files_list_idx
    ON files (owner_id, parent_id)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX files_root_name_uidx
    ON files (owner_id, lower(name))
    WHERE deleted_at IS NULL AND parent_id IS NULL;
CREATE UNIQUE INDEX files_child_name_uidx
    ON files (parent_id, lower(name))
    WHERE deleted_at IS NULL AND parent_id IS NOT NULL;
CREATE INDEX files_deleted_idx ON files (deleted_at) WHERE deleted_at IS NOT NULL;

CREATE TABLE file_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    file_id UUID NOT NULL REFERENCES files (id) ON DELETE RESTRICT,
    version_number INTEGER NOT NULL,
    size BIGINT NOT NULL,
    content_sha256 CHAR(64),
    created_by UUID NOT NULL REFERENCES users (id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT file_versions_number_chk CHECK (version_number >= 1),
    CONSTRAINT file_versions_size_chk CHECK (size >= 0),
    CONSTRAINT file_versions_hash_chk CHECK (
        content_sha256 IS NULL OR content_sha256 ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT file_versions_file_number_uk UNIQUE (file_id, version_number)
);

CREATE INDEX file_versions_file_idx ON file_versions (file_id, version_number DESC);

ALTER TABLE files
    ADD CONSTRAINT files_current_version_fk
    FOREIGN KEY (current_version_id) REFERENCES file_versions (id)
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE chunks (
    id CHAR(64) PRIMARY KEY,
    size INTEGER NOT NULL,
    ref_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chunks_id_chk CHECK (id ~ '^[0-9a-f]{64}$'),
    CONSTRAINT chunks_size_chk CHECK (size >= 1 AND size <= 4194304),
    CONSTRAINT chunks_ref_count_chk CHECK (ref_count >= 0)
);

CREATE INDEX chunks_gc_idx ON chunks (id) WHERE ref_count = 0;

CREATE TABLE file_version_chunks (
    version_id UUID NOT NULL REFERENCES file_versions (id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    chunk_id CHAR(64) NOT NULL REFERENCES chunks (id),
    size INTEGER NOT NULL,
    CONSTRAINT file_version_chunks_pk PRIMARY KEY (version_id, ordinal),
    CONSTRAINT file_version_chunks_ordinal_chk CHECK (ordinal >= 0),
    CONSTRAINT file_version_chunks_size_chk CHECK (
        size >= 1 AND size <= 4194304
    )
);

CREATE INDEX file_version_chunks_chunk_idx ON file_version_chunks (chunk_id);

CREATE TABLE chunk_replicas (
    chunk_id CHAR(64) NOT NULL REFERENCES chunks (id) ON DELETE CASCADE,
    node_id UUID NOT NULL REFERENCES nodes (id),
    status TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chunk_replicas_pk PRIMARY KEY (chunk_id, node_id),
    CONSTRAINT chunk_replicas_status_chk CHECK (
        status IN ('writing', 'ok', 'missing')
    )
);

CREATE INDEX chunk_replicas_node_status_idx ON chunk_replicas (node_id, status);
CREATE INDEX chunk_replicas_ok_idx ON chunk_replicas (chunk_id) WHERE status = 'ok';

CREATE TABLE shares (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token CHAR(64) NOT NULL,
    file_id UUID NOT NULL REFERENCES files (id),
    created_by UUID NOT NULL REFERENCES users (id),
    access_level TEXT NOT NULL,
    expires_at TIMESTAMPTZ,
    is_public BOOLEAN NOT NULL DEFAULT FALSE,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT shares_token_uk UNIQUE (token),
    CONSTRAINT shares_token_chk CHECK (token ~ '^[0-9a-f]{64}$'),
    CONSTRAINT shares_access_chk CHECK (access_level IN ('read', 'write'))
);

CREATE INDEX shares_file_idx ON shares (file_id);
CREATE INDEX shares_expires_idx ON shares (expires_at) WHERE revoked_at IS NULL;

CREATE TABLE share_permissions (
    share_id UUID NOT NULL REFERENCES shares (id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    access_level TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT share_permissions_pk PRIMARY KEY (share_id, user_id),
    CONSTRAINT share_permissions_access_chk CHECK (
        access_level IN ('read', 'write')
    )
);

CREATE INDEX share_permissions_user_idx ON share_permissions (user_id);

CREATE OR REPLACE FUNCTION files_parent_must_be_folder()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.parent_id IS NULL THEN
        RETURN NEW;
    END IF;
    PERFORM 1
    FROM files p
    WHERE p.id = NEW.parent_id
      AND p.is_folder
      AND p.deleted_at IS NULL
      AND p.owner_id = NEW.owner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'parent_id must reference a live folder owned by the same user';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER files_parent_must_be_folder_trg
    BEFORE INSERT OR UPDATE OF parent_id, owner_id
    ON files
    FOR EACH ROW
    EXECUTE PROCEDURE files_parent_must_be_folder();
