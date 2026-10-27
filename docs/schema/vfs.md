# VFS Database schema (`noizu_mcp_vfs_nodes`)

Shipped Liquibase template `priv/liquibase/noizu_mcp_vfs.yaml` backs
`Noizu.MCP.VFS.Database`, the Postgres-backed VFS backend. Same template rules
as the OAuth/agent/sync sets: the host copies it into its own changelog
directory (renumber the changeSet ids, set `author:`) — the library owns no
database. The changeSet is idempotent (`CREATE TABLE IF NOT EXISTS`), so it
can also be hand-applied with psql.

## noizu_mcp_vfs_nodes

Files are rows with `data` BYTEA content; directories are explicit rows (so
empty dirs persist). The root row is seed data, not schema:

```sql
INSERT INTO noizu_mcp_vfs_nodes (path, parent_path, type)
VALUES ('/', NULL, 'dir') ON CONFLICT (path) DO NOTHING;
```

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| path | text | No | — | Primary key; absolute VFS path |
| parent_path | text | Yes | NULL | Parent directory path (maintained by the backend; NULL for root) |
| type | varchar(8) | No | — | CHECK (`file` / `dir`) |
| data | bytea | Yes | NULL | File content; NULL for directories |
| mime | text | Yes | NULL | File MIME type |
| writable | boolean | No | true | Backend write gate |
| version | bigint | No | 1 | Monotonic counter the backend bumps on every write — do not rewrite by hand |
| mtime | bigint | No | 0 | Unix milliseconds |
| created_at | timestamptz | No | now() | Library timestamp convention |
| updated_at | timestamptz | No | now() | Library timestamp convention |

**Indexes**: `idx_noizu_mcp_vfs_nodes_parent` (`parent_path`) — children listing.
**Constraints**: `path` PK — hierarchy is logical via `parent_path`, no FK; `type` CHECK (`file`/`dir`).
**Rollback**: `DROP TABLE IF EXISTS noizu_mcp_vfs_nodes CASCADE`.
