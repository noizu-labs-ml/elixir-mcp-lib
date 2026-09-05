---
id: ADR-003
title: "SQL projection model: catalog tables, INSERT-driven tool calls, per-tool tables/functions/views"
status: accepted
date: 2026-09-05
---

# ADR-003: How MCP surfaces appear in SQL

> Implements ADR-001. Normative DDL lives in PRD-7 (catalog/invocation) and PRD-8 (codegen).

## Context

MCP exposes four listable surfaces (tools, prompts, resources, resource templates), three
"fetch" operations (`tools/call`, `prompts/get`, `resources/read`), completion, and — for
elixir-mcp servers — VFS trees and, with ADR-005, arbitrary datasets. SQL has tables (read),
DML (write), and functions (call). The user asked for **all three invocation styles**:
functions, INSERT-driven calls, and per-tool views/tables.

Tool invocation has side effects. A `SELECT` that silently runs a `delete_project` tool is
unacceptable; the MCP `annotations.readOnlyHint` flag exists for exactly this distinction.

## Decision

One schema per foreign server, created by `IMPORT FOREIGN SCHEMA mcp FROM SERVER <s> INTO <schema>`
(or `mcp.import(server, schema, opts)`). Extension-owned functions live in schema `mcp`.

### Catalog foreign tables (read-only)
`server` (one row) · `tools` (name, title, description, input_schema, output_schema,
annotations jsonb, read_only, destructive, idempotent, open_world) · `prompts` ·
`prompt_arguments` (derived) · `resources` · `resource_templates` ·
`resource_contents` (uri, mime_type, text, blob; `uri = …`/`= ANY(…)` pushed to
`resources/read`; unqualified scans capped by server option `max_unqualified_reads`) ·
`prompt_messages` (prompt, arguments jsonb, idx, role, content jsonb, text; `prompt =` required)
· `completions` · later `vfs_entries`/`vfs_files` for VFS-capable servers.

### Invocation
1. **`tool_calls` foreign table** — `INSERT INTO s.tool_calls(tool, arguments) VALUES (…) RETURNING *`
   invokes `tools/call` and returns `content`, `structured`, `is_error`, `error`, timing.
   `SELECT` returns this backend's call log (bounded ring); server option `audit_table` may
   mirror rows into a local table.
2. **Functions** in `mcp`: `call_tool(server, tool, args jsonb) → jsonb`, `call_tool_text`,
   `get_prompt`, `read_resource`, `complete`, `refresh`, `import`, `generate_functions`.
3. **Per-tool objects**, generated at import for every tool:
   - foreign table `tool_<name>`: input-schema properties become columns used as quals
     (arguments); output-schema properties become result columns (top-level array-of-objects
     → one row per element, otherwise one row); always `content jsonb`, `is_error`.
     **SELECT-invocation is generated only when `readOnlyHint = true`** (or import option
     `invoke_on_select = 'all'`); other tools' tables are INSERT-only.
   - typed SQL function `<schema>.<name>(arg1 type, arg2 type DEFAULT NULL) RETURNS jsonb`
     (or `SETOF record` when an output schema exists), wrapping `mcp.call_tool`.
   - view `v_tool_<name>` flattening structured output when an output schema exists.

### Type mapping (JSON Schema → Postgres)
string→`text` (`format: date-time`→`timestamptz`, `date`→`date`, `uuid`→`uuid`),
integer→`bigint`, number→`double precision`, boolean→`boolean`, enum→`text`,
object/array→`jsonb`; nullable unless listed in `required`. Unknown/any → `jsonb`.

### Errors
JSON-RPC errors map to SQLSTATEs (invalid params→`22023`, forbidden→`42501`, method not
found→`0A000`, transport→`08006`). A tool result with `isError: true` is **data**, not an
exception, in tables (`is_error = true`); functions raise unless called with
`on_error => 'return'`.

### Identifiers
snake_case, lower-cased, non-identifier characters → `_`, 63-byte limit with a short hash
suffix on truncation, deterministic collision suffixes; original MCP names kept in the
`tools` catalog so nothing is lost.

## Consequences

Positive
- Read-only tools feel like parameterised tables and join naturally; mutating tools require
  an explicit write or call, matching user intent and MCP annotations.
- Everything derives from the server's live catalog (one resolver, no parallel registry);
  `refresh`/`list_changed` regenerates.
- Functions give ORM-free callers a typed surface; `tool_calls` gives ORMs a write path.

Negative / risks
- Generated objects can churn when a server's tool list changes; import is idempotent and
  regeneration drops/recreates only `tool_*` objects it owns.
- Unqualified scans of `resource_contents` or SELECT-invocable tools are potentially
  expensive; caps and `LIMIT` pushdown are mandatory.
- Servers that mislabel `readOnlyHint` can make a mutating tool SELECT-invocable; the import
  option `invoke_on_select = 'none'` exists for distrusted servers.

## Alternatives considered
- Functions only — rejected by the user (no table-shaped reads, poor BI/ORM fit).
- Views with WHERE-as-argument only — surprising semantics without the readOnly gate.
- One SELECT-invocable table per tool regardless of annotations — unsafe.

## References
- MCP spec 2025-11-25 tools/annotations (`docs/03-tools.md`), prompts/resources (`docs/04-resources.md`, `docs/05-prompts-sampling-roots.md`).
- elixir-mcp tool wire struct `lib/noizu/mcp/types/tool.ex`, field DSL `lib/noizu/mcp/server/tool/fields.ex`.
