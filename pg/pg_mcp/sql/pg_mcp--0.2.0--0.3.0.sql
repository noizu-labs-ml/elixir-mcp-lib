-- pg_mcp 0.2.0 → 0.3.0 (PRD-8: per-tool codegen).
--
-- Applied by `ALTER EXTENSION pg_mcp UPDATE TO '0.3.0'`. Purely additive
-- (PRD-8 §8): PRD-7's nine tables, their handlers and every 0.2.0 import
-- keep working unchanged — a database imported under PRD-7 needs no
-- re-import after the upgrade. The delta is exactly two objects:
--
--   * mcp.generated — the generation bookkeeping table (names and
--     provenance only; AP-P7: never a copy of a tool schema).
--   * mcp.generate_functions(server, schema, opts) — the §4.6 generation
--     entry point. Runtime support for the per-tool tables it creates
--     (the `tool`/`invoke_on_select` table options, the §4.1 type map)
--     lives in the 0.3.0 shared library this upgrade loads.
--
-- Existing per-tool objects created before the upgrade (there are none:
-- 0.2.0 refused `per_tool` with 0A000) would need regeneration; nothing
-- else is touched and no data migrates.

CREATE TABLE mcp.generated (
  server text NOT NULL,
  schema text NOT NULL,
  kind text NOT NULL,
  name text NOT NULL,
  tool text NOT NULL,
  generated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (schema, name)
);

COMMENT ON TABLE mcp.generated IS
  'Per-tool generation bookkeeping (PRD-8 section 4.6): names and provenance of the SQL objects pg_mcp created from MCP tool definitions. Never a copy of a tool schema - regeneration always re-reads from the server.';

CREATE FUNCTION mcp."generate_functions"(
	"server" TEXT,
	"schema" TEXT,
	"opts" jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE (
	"generated" INT,
	"skipped" INT,
	"skipped_tools" TEXT[]
)
STRICT VOLATILE PARALLEL UNSAFE
LANGUAGE c
AS 'MODULE_PATHNAME', 'generate_functions_wrapper';

COMMENT ON FUNCTION mcp.generate_functions(text, text, jsonb) IS
  'PRD-8: generate (or regenerate) the per-tool SQL objects for a server into a schema; drops and recreates only the objects recorded in mcp.generated (RESTRICT).';
