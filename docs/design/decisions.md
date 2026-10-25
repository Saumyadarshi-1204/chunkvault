# Architecture decisions

## ADR 1: Fixed 4 MiB chunks

**Context.** Files must be split into addressable units for placement, integrity checks, and partial retry. Variable or content-defined chunking improves deduplication of similar files but needs a rolling-hash implementation, harder size bounds, and more metadata per file.

**Decision.** Use a fixed chunk size of 4 MiB (4 × 1024 × 1024 bytes). The last chunk of a file may be smaller. Chunk ID is SHA-256 of the chunk bytes.

**Trade-offs.** Implementation, request limits, and storage-node PUT checks stay simple; every full chunk is the same max size. Sequential files from the same client share chunks only when byte ranges match exactly. Many files just under 4 MiB become a single chunk. Changing the size later would require a new generation of chunk IDs and a migration.

## ADR 2: Replication factor 2 (configurable)

**Context.** The baseline cluster has three storage nodes. The system must survive a single node loss without losing bytes, without paying the disk and write-amplification cost of three copies of every chunk.

**Decision.** Default `replication_factor` is 2, read from configuration, and must not exceed the number of enabled live nodes. The API writes each new chunk to that many distinct nodes and records replicas in PostgreSQL.

**Trade-offs.** One node failure remains readable and repairable from the other replica. Two concurrent node failures can lose data whose only copies lived on those two nodes. Writes cost two PUTs of 4 MiB per full chunk. Operators can raise the factor only when more nodes exist; lowering it does not delete extra replicas until GC or a dedicated rebalance.

## ADR 3: Soft delete with reference-count GC

**Context.** Files can share chunks through identical 4 MiB slices. Immediate physical delete of a file’s chunks would corrupt other files. Immediate metadata-only delete without a later sweep would leak disk.

**Decision.** `DELETE` on a file marks it deleted (`deleted_at`) and leaves chunk bytes in place. Garbage collection walks that file’s chunks, decrements `chunks.refcount`, and issues storage-node `DELETE /chunks/{id}` only when the count reaches zero.

**Trade-offs.** Deleted files remain recoverable until GC runs, which is useful and must be access-controlled. GC is a correctness-critical path: it must lock or compare-and-swap the `chunks` row so an upload cannot race a decrement to zero. Operators need a lag metric between soft delete and space reclamation. Tombstones accumulate until GC.

## ADR 4: PostgreSQL for metadata, not a NoSQL store

**Context.** Metadata includes users, files, ordered chunk lists, reference counts, and replica tuples. These need transactions (upload commit, refcount, replica insert) and relational constraints. Document or key-value stores handle blobs and flexible documents well but make multi-row invariants and GC harder.

**Decision.** PostgreSQL is the system of record for all metadata. Redis is limited to hashed refresh tokens, node heartbeat TTLs, and caches. Chunk payloads stay on storage nodes, not in either database.

**Trade-offs.** Transactions and foreign keys match refcount GC and replica accounting. Schema migrations are explicit. PostgreSQL is not used as a blob store, so payload scale does not land in WAL. A NoSQL catalog would ease horizontal metadata sharding later but would push integrity (refcount, replica quorum) into application code that is easier to get wrong. Cache invalidation in Redis can serve stale locations; PostgreSQL remains authoritative after a miss.
