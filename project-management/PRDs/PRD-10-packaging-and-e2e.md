# PRD-10: Packaging, Image, CI & End-to-End Harness

**Series**: pg_mcp — MCP servers as Postgres structures (PRD-10 of 6, series close)
**Repo**: `Portfolio/Libs/ai/elixir-mcp` — `pg/pg_mcp/`, `pg/docker/`, `.github/workflows/`, `test/noizu/mcp/sql/` — plus a documented infra change in the monorepo (`terraform/`).
**Version policy**: no further `mix.exs` bump. `0.4.0` shipped in PRD-11 and is on hex by the time this PRD merges. The extension image gets its own tag.
**Depends on**: PRD-6, 9, 11, 7 and 8 all merged; `0.4.0` published (in PRD-11).
**Date**: 2026-09-05 · **Author**: npl-prd-editor (Loom weave)
**Status**: Draft

---

## 1. Goal

Make `pg_mcp` installable on the Noizu cluster, buildable in CI for every supported PostgreSQL major, and provably correct against a real Elixir MCP server through a real Postgres.

Deliverables:

1. `pg/docker/Dockerfile` layering the compiled extension onto the cluster's TimescaleDB image.
2. A GitHub Actions workflow running `cargo pgrx package` for pg16, pg17 and pg18, plus the Rust test suites.
3. An Elixir end-to-end suite, `test/noizu/mcp/sql/pg_mcp_e2e_test.exs`, tagged `:pg_mcp` and skipped unless `PG_MCP_URL` is set, that boots a real `Noizu.MCP.Engine` on Bandit with stdio upstreams attached and drives a real Postgres through Postgrex.
4. An operator install runbook.
5. The Terraform image-bump note for the cluster.

**Explicitly OUT of scope**: rolling the image out to production (an operator decision, on the deploy tiers in `.infra-config.yaml`); rebuilding the base TimescaleDB image itself (its source is outside this workspace — see §9 Q1).

---

## 2. Decision log applied to this PRD

| ADR / rule | How it binds this PRD |
|---|---|
| **ADR-007** engine federation | The **first e2e target is the engine**, not a bare fixture server. The suite boots `Noizu.MCP.Engine` with two stdio fixture upstreams attached, registers **one** foreign server, and asserts the install-once story end to end: attach an MCP with an `INSERT`, see its tools appear in SQL. Generic mode against a single server is still covered, as the fallback it is. |
| **ADR-006** placement | `pg/` stays a subproject inside the lib repo, alongside `daemon/mcp_mount/`. The hex package remains pure Elixir: the packaging test in §7.6 fails the build if `pg/` appears in the tarball. Distribution of the extension is **image layering**, not hex, not PGXN. |
| **ADR-002** pgrx | `cargo pgrx package` is the build command; it produces a directory tree that drops onto a Postgres install. Cross-major builds are separate jobs because pgrx links against each major's headers. |
| **ADR-001** real extension | The artifact is a `.so` plus control and SQL files installed into the image's `pkglibdir` and `sharedir`. Nothing about the deployment introduces a proxy process. |
| **ADR-004** identity | The e2e suite's headline assertions are the identity ones: a bad token yields `42501` with **no** `%Principal{}` synthesized server-side, and two `USER MAPPING`s see two different tool sets. If those two fail, the series does not ship. |
| **D5 fail-open per server** | The image must be usable with the extension present but unloaded. `pg_mcp` is not added to `shared_preload_libraries`; it loads on `CREATE EXTENSION`. A database that never creates it is unaffected. |

---

## 3. Background

The cluster's Postgres is a plain Terraform deployment of `docker.io/noizu/timescaledb-ha-with-age:pg17.9-ts2.25.2-all-age1.7.0-r2`, pinned at `terraform/kubernetes/modules/timescaledb/variables.tf:22-26`. It runs as uid 1000 and ships citext, uuid-ossp, vector, cube, pg_trgm, earthdistance, pgcrypto, timescaledb and age — and none of `wrappers`, `multicorn`, `http`, `plpython3u` or `postgres_fdw`. That absence is precisely why ADR-002 chose a self-contained compiled extension: there is no host framework to plug into, so the artifact must carry everything.

Adding an extension therefore means a new image tag layered on that base. The base image's own build lives outside this workspace, which is a real gap (§9 Q1): we can layer, but we cannot currently regenerate the thing we are layering onto, and a base bump means finding whoever owns it.

The engine (PRD-11) changes what this suite must prove. The headline claim of ADR-007 is "install once": one extension, one foreign server, and every further MCP attached as a row. That claim is only true if a `INSERT INTO engine.servers` genuinely makes an upstream's tools appear as SQL objects, through a real Postgres, against a real stdio MCP process. Nothing short of an end-to-end test establishes it, which is why the engine is the first target here and generic mode is the secondary one.

On the test side, the library already has the two halves this suite needs. `test/noizu/mcp/transport/streamable_http_test.exs:26-30` boots `Noizu.MCP.Fixtures.Server` behind a real Bandit listener with `Noizu.MCP.Test.ensure_server_started/1`. And `postgrex` is already a dev/test dependency (`mix.exs:52`), so driving a Postgres from ExUnit needs no new dep. What has never existed is the two halves in one test: an MCP server and a Postgres that talks to it.

---

## 4. Public surface

### 4.1 `pg/docker/Dockerfile`

Two stages. The builder compiles against the *exact* PostgreSQL major of the runtime base; the runtime copies only the artifacts.

```dockerfile
# ---- builder ----
FROM rust:1-bookworm AS builder
ARG PG_MAJOR=17
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-server-dev-${PG_MAJOR} clang libclang-dev pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*
RUN cargo install cargo-pgrx --version 0.19.2 --locked
RUN cargo pgrx init --pg${PG_MAJOR} $(which pg_config)
WORKDIR /src
COPY pg/pg_mcp /src
RUN cargo pgrx package --pg-config $(which pg_config) --out-dir /out

# ---- runtime ----
FROM docker.io/noizu/timescaledb-ha-with-age:pg17.9-ts2.25.2-all-age1.7.0-r2
USER root
COPY --from=builder /out/usr/lib/postgresql/17/lib/pg_mcp.so        /usr/lib/postgresql/17/lib/
COPY --from=builder /out/usr/share/postgresql/17/extension/pg_mcp*  /usr/share/postgresql/17/extension/
RUN chmod 0644 /usr/lib/postgresql/17/lib/pg_mcp.so \
               /usr/share/postgresql/17/extension/pg_mcp*
USER 1000
```

Normative constraints:

- `PG_MAJOR` must match the base image's major. A mismatch is caught by the smoke test in §7.5, which runs `CREATE EXTENSION pg_mcp` in the built image and fails the build on error.
- The final `USER 1000` restores the base image's runtime user; nothing in the layer runs as root at runtime.
- The extension is **not** added to `shared_preload_libraries`. No `postgresql.conf` change; no restart semantics beyond a normal image roll.
- Exact library and extension paths are read from `pg_config --pkglibdir` / `--sharedir` in the builder rather than hardcoded; the literal paths above are the expected values for the pinned base and are asserted, not assumed.

**Local development** uses a stock `postgres:17` base with the identical `COPY` layering (ADR-006), so a contributor needs neither the Noizu base image nor a registry login. The builder stage is shared; only the runtime `FROM` differs, selected by a `BASE_IMAGE` build arg defaulting to the production base. The e2e suite runs against either.

Tag scheme: `docker.io/noizu/timescaledb-ha-with-age-mcp:pg17.9-ts2.25.2-all-age1.7.0-mcp0.4.0-r1` — the base tag with `-mcp<extension version>-r<layer revision>` appended, so the base provenance stays legible.

### 4.2 GitHub Actions workflow — `.github/workflows/pg_mcp.yml`

| Job | Matrix | Steps |
|---|---|---|
| `test` | `pg: [16, 17, 18]` | `cargo pgrx init --pg<N>`; `cargo fmt --check`; `cargo clippy -- -D warnings`; `cargo pgrx test pg<N>` |
| `package` | `pg: [16, 17, 18]` | `cargo pgrx package`; upload the out-dir as an artifact named `pg_mcp-pg<N>` |
| `image` | pg17 only | build `pg/docker/Dockerfile`; run the §7.5 smoke test; push only on a tag |
| `e2e` | pg17 only | build the image; `docker run` it; boot the Elixir suite with `PG_MCP_URL` set; `mix test --only pg_mcp` |

Triggers: `pull_request` and `push` touching `pg/**` or `.github/workflows/pg_mcp.yml`. The `image` and `e2e` jobs need `package` to succeed first. Pushes to a registry happen only on tag builds; PRs build and discard.

The workflow runs independently of the existing Elixir CI, so a Rust failure never blocks a pure-Elixir PR and vice versa.

### 4.3 End-to-end suite — `test/noizu/mcp/sql/pg_mcp_e2e_test.exs`

```elixir
defmodule Noizu.MCP.SQL.PgMcpE2ETest do
  use ExUnit.Case, async: false
  @moduletag :pg_mcp

  alias Noizu.MCP.Fixtures

  setup_all do
    if url = System.get_env("PG_MCP_URL") do
      # 1. Boot Noizu.MCP.Engine behind Bandit on an ephemeral port, with two
      #    stdio fixture upstreams attached and one deliberately broken upstream.
      # 2. Connect Postgrex to the docker Postgres named by PG_MCP_URL.
      # 3. CREATE EXTENSION pg_mcp; CREATE SERVER engine; CREATE USER MAPPING (x2).
      # 4. IMPORT FOREIGN SCHEMA mcp ... OPTIONS (per_tool 'true', all_upstreams 'true').
      ...
    else
      {:ok, skip: true}
    end
  end
end
```

Skip mechanics: the suite is tagged `:pg_mcp`, and `test/test_helper.exs` gains `ExUnit.configure(exclude: [:pg_mcp])` so it never runs in the default `mix test`. `PG_MCP_URL` is a Postgrex-style connection URL pointing at a Postgres running the layered image. `mix test --only pg_mcp` with the variable unset reports the suite as excluded rather than failing.

The Bandit listener follows the existing pattern at `test/noizu/mcp/transport/streamable_http_test.exs:26-30` (`Noizu.MCP.Test.ensure_server_started/1` plus a `StreamableHTTP.Plug` with an `:auth` verifier), binding to `0.0.0.0` on an ephemeral port so the container can reach it, and the `CREATE SERVER` URL uses `host.docker.internal` (or the CI network alias) rather than `localhost`.

### 4.4 E2E assertions (the point of the whole series)

| # | Assertion |
|---|---|
| **E1** | `SELECT count(*) FROM mcp.tools` equals the length of a direct `Noizu.MCP.Test` `list_tools` call as the same principal. |
| **E2** | `SELECT name, description, input_schema FROM mcp.tools ORDER BY name` matches `tools/list` field-for-field, including `input_schema` jsonb equality. |
| **E3** | `INSERT INTO mcp.tool_calls (tool, arguments) VALUES ('echo','{"message":"hi"}') RETURNING content` equals a direct `tools/call` result. |
| **E4** | A failing tool inserted alongside a succeeding one in one statement returns `is_error = true` for the first and a result for the second; the statement commits. |
| **E5** | Per-tool WHERE invocation: `SELECT * FROM tool_<read_only> WHERE <arg> = '...'` returns typed rows equal to the equivalent `tools/call`. |
| **E6** | `SELECT * FROM tool_<non_read_only> WHERE ...` raises `0A000`; the INSERT form succeeds. |
| **E7** | `SELECT * FROM mcp.prompt_messages WHERE prompt = '<p>'` equals `prompts/get`. |
| **E8** | `SELECT * FROM mcp.resource_contents WHERE uri = '<u>'` equals `resources/read`. |
| **E9** | **Bad token → `42501`, and the server-side handler observed no `%Principal{}`.** The fixture records every request's principal in an Agent; the test asserts the entry for that request is `nil`. No anonymous principal is synthesized (ADR-004). |
| **E10** | **Two `USER MAPPING`s see different tool sets.** Two Postgrex connections as two roles, one foreign server, two tokens resolving to two principals with different ACLs; `SELECT name FROM mcp.tools` differs, and neither is a superset by accident (both directions asserted). |
| **E11** | Qual honesty (PRD-9 AP-P12): a deliberately lying dataset returning extra rows still yields a correct SQL result, because Postgres re-checks. |
| **E12** | `mcp.refresh('<s>')` followed by a tool-set change server-side is reflected in the next `SELECT FROM mcp.tools`. |
| **E13** | `mcp.generate_functions` regeneration after a server-side schema change updates the generated column types. |
| **E14** | A `pg_dump`/`pg_restore` round trip of the whole test database restores servers, mappings and foreign tables intact. |
| **E15** | **Install once.** With the engine already registered as the single foreign server, `INSERT INTO engine.servers (name, transport, command, auth_ref, enabled) VALUES ('extra','stdio',…)` followed by `mcp.refresh('engine')` and `mcp.generate_functions('engine','extra')` makes that upstream's tools callable as `extra.<tool>(…)`. No `CREATE SERVER`, no `USER MAPPING`, no Postgres restart. |
| **E16** | `SELECT name, transport, status, tool_count FROM engine.servers` reports live status per upstream; the deliberately broken upstream reads `error` while every other row reads `ready`, and `SELECT count(*) FROM mcp.tools` is unaffected by it. |
| **E17** | `DELETE FROM engine.servers WHERE name = 'extra'` removes its tools from `mcp.tools`; a subsequent `mcp.generate_functions` drops that upstream's schema objects and leaves the others intact. |
| **E18** | Per-upstream schemas: `all_upstreams 'true'` creates one schema per attached upstream plus the engine's own, and a tool reachable at `github.create_issue(…)` carries no redundant prefix in its name. |
| **E19** | Generic mode still works: a second foreign server pointing directly at a bare `Fixtures.Server` (not the engine) imports and behaves per PRD-7, alongside the engine server in the same database. |

### 4.5 Install runbook — `guides/postgres.md` §Install

Operator steps, in order:

1. Build and push the layered image (§4.1) or pull the published tag.
2. Bump `terraform/kubernetes/modules/timescaledb/variables.tf` `image` default (`:22-26`) or the per-deployment override, then `terragrunt apply` in `terraform/kubernetes`. This is an image roll: expect a pod restart, which for a TimescaleDB HA deployment means a failover. Schedule accordingly.
3. Deploy the engine (PRD-11) — embedded in a host app behind the Streamable HTTP plug, or standalone. It is the thing Postgres will point at.
4. Per database: `CREATE EXTENSION pg_mcp;` (requires superuser or `pg_create_foreign_server` plus `CREATE` on the target schema).
5. `CREATE SERVER engine FOREIGN DATA WRAPPER mcp_fdw OPTIONS (url '<engine url>', mode 'auto')` — **one** foreign server, for the engine. Generic mode remains available for pointing directly at a single MCP server, but the engine is the intended path.
6. `CREATE USER MAPPING FOR <role> SERVER engine OPTIONS (token_secret 'mcp_secrets.<row>')` — tokens sourced from Infisical through the existing secrets flow, never typed into a migration.
7. `IMPORT FOREIGN SCHEMA mcp FROM SERVER engine INTO <schema> OPTIONS (per_tool 'true', all_upstreams 'true');`
8. Attach MCP servers as rows, thereafter: `INSERT INTO engine.servers (name, transport, command, auth_ref, enabled) VALUES (…)`, then `SELECT mcp.refresh('engine')` and `SELECT * FROM mcp.generate_functions('engine', '<upstream>')`. Note that `auth_ref` holds a **reference**, never a token (PRD-11 §4.2).
9. Check the DDL from steps 4–7 into a Liquibase changelog, per the monorepo convention that Liquibase owns schema. Generated per-tool objects are DDL and must not be hand-run in production. Step 8's `INSERT` is data, not schema, and belongs wherever the operator keeps configuration.

Uninstall: `DROP EXTENSION pg_mcp CASCADE` per database, then roll the image back. Local audit tables survive deliberately.

### 4.6 Terraform note

The image variable at `terraform/kubernetes/modules/timescaledb/variables.tf:22-26` currently defaults to the un-layered base. Bumping it is an infra change in the monorepo, outside this repo and outside this PR. This PRD **documents** the bump and its blast radius; it does not perform it. The PR description carries the exact one-line diff so an operator can apply it deliberately.

---

## 5. Requirements

**FR-10.1** `pg/docker/Dockerfile` builds a runnable image layering `pg_mcp.so` and its control/SQL files onto the pinned base, resolving install paths from `pg_config`. A `BASE_IMAGE` build arg selects a stock `postgres:17` for local development (ADR-006) with no other change.
**FR-10.2** The image runs as uid 1000; no runtime process runs as root; no `shared_preload_libraries` change.
**FR-10.3** `CREATE EXTENSION pg_mcp` succeeds in the built image, and every pre-existing extension (timescaledb, age, vector, pgcrypto, citext, uuid-ossp, cube, pg_trgm, earthdistance) still creates successfully in the same database.
**FR-10.4** `.github/workflows/pg_mcp.yml` runs fmt, clippy (`-D warnings`), `cargo pgrx test` and `cargo pgrx package` for pg16, pg17 and pg18.
**FR-10.5** The workflow builds the image and runs the §7.5 smoke test on every PR touching `pg/**`; it pushes only on tags.
**FR-10.6** `test/noizu/mcp/sql/pg_mcp_e2e_test.exs` exists, tagged `:pg_mcp`, excluded by default in `test/test_helper.exs`, and skipped cleanly when `PG_MCP_URL` is unset.
**FR-10.7** The suite boots `Noizu.MCP.Engine` on Bandit reachable from the container, with stdio fixture upstreams attached, and drives Postgres through Postgrex (`mix.exs:52`) with no new dependency.
**FR-10.8** All nineteen assertions E1–E19 (§4.4) are implemented and pass.
**FR-10.13** The suite registers exactly **one** foreign server for the engine path, proving the install-once claim; the generic-mode server in E19 is a deliberate second registration and is the only other one.
**FR-10.9** The suite creates and tears down everything it uses; a re-run on a dirty database succeeds.
**FR-10.10** `guides/postgres.md` carries the §4.5 runbook including the Liquibase instruction and the failover warning.
**FR-10.11** The PR description carries the exact Terraform one-line diff for `variables.tf:22-26`; the file itself is not modified in this repo.
**FR-10.12** A packaging test asserts the hex tarball contains no `pg/` path.

**Acceptance criteria**

**AC-10.1** `docker build -f pg/docker/Dockerfile .` succeeds locally and in CI, both at the default base and with `--build-arg BASE_IMAGE=postgres:17`.
**AC-10.2** The smoke test (§7.5) passes: extension creates, `SELECT mcp.refresh('x')` raises `42704` (proving the functions exist and resolve server names), and every pre-existing extension still creates.
**AC-10.3** `cargo pgrx test` green on pg16, pg17, pg18 in CI.
**AC-10.4** `mix test` with no flags does not run the e2e suite and stays green.
**AC-10.5** `mix test --only pg_mcp` with `PG_MCP_URL` unset reports the suite excluded, exit code 0.
**AC-10.6** `mix test --only pg_mcp` with `PG_MCP_URL` set against the built image passes all of E1–E19.
**AC-10.7** **E9, E10 and E15 pass** — the two identity assertions plus install-once. These three are the series' go/no-go at merge: without E9 and E10 the security model is unproven, and without E15 ADR-007's central claim is unproven.
**AC-10.8** `mix hex.build` produces a tarball with no `pg/` entry (FR-10.12).
**AC-10.9** The image is under 200MB larger than its base (the `.so` plus SQL files should be a few MB; a larger delta means builder artifacts leaked into the runtime stage).
**AC-10.10** A second `mix test --only pg_mcp` run immediately after the first passes without manual cleanup (FR-10.9).

---

## 6. Internal work checklist (with anchors)

| Step | File | Anchor / detail |
|---|---|---|
| 10.1 | `pg/docker/Dockerfile` | new; §4.1, base pinned to `docker.io/noizu/timescaledb-ha-with-age:pg17.9-ts2.25.2-all-age1.7.0-r2` |
| 10.2 | `pg/docker/smoke.sql` | new; §7.5 smoke script run in the image job |
| 10.3 | `.github/workflows/pg_mcp.yml` | new; §4.2 job matrix |
| 10.4 | `test/noizu/mcp/sql/pg_mcp_e2e_test.exs` | new; §4.3/§4.4; Bandit boot pattern from `test/noizu/mcp/transport/streamable_http_test.exs:26-30`, serving `Noizu.MCP.Engine` (PRD-11 §4.9) |
| 10.4b | `test/support/fixture_engine.ex` | extend PRD-11 step 11.9 with upstreams whose stdio commands are runnable inside CI (an escript or `elixir -e`, not an `npx` download) |
| 10.5 | `test/support/fixture_sql.ex` | extend PRD-9 step 9.9 with a principal-recording Agent for E9 and a lying dataset for E11 |
| 10.6 | `test/support/fixture_auth.ex` | reuse the existing auth fixture for the two-principal setup (E10); add a second token/ACL pair |
| 10.7 | `test/test_helper.exs` | `ExUnit.configure(exclude: [:pg_mcp])` |
| 10.8 | `guides/postgres.md` | §4.5 runbook (file created in PRD-9 step 9.12; extended here) |
| 10.9 | `mix.exs` | packaging test support only; **no version change** |
| 10.10 | `test/noizu/mcp/packaging_test.exs` | FR-10.12 tarball assertion |
| 10.11 | PR description | §4.6 Terraform diff for `terraform/kubernetes/modules/timescaledb/variables.tf:22-26` (monorepo, not edited here) |

---

## 7. Test plan

### 7.1 Rust (CI matrix)

Everything from PRD-6 §7.1, PRD-7 §7.1–7.3 and PRD-8 §7.1–7.3, run for pg16/17/18. No new Rust tests originate in this PRD.

### 7.2 Elixir default suite

Unchanged and green. The e2e file is excluded by tag, so `mix test`, `mix format --check-formatted`, `mix credo` and `mix dialyzer` behave exactly as after PRD-9.

### 7.3 End-to-end (§4.4)

E1–E14, run in CI's `e2e` job and runnable locally with a `docker run` of the built image plus `PG_MCP_URL`.

### 7.4 Anti-pattern regression tests, end-to-end

The series' four identity- and safety-critical patterns are re-asserted here against real components, not stubs:

- **AP-P2 e2e** (SELECT with side effects): counted against the fixture server's request log — a `SELECT` on `tool_calls` produces zero `tools/call` entries.
- **AP-P5 e2e** (silent side effects): `SELECT` on a non-read-only per-tool table raises, and the fixture server records no request at all.
- **AP-P10 e2e** (auth bypass) = **E9**.
- **AP-P12 e2e** (qual trust) = **E11**.
- **AP-P15 e2e** (one upstream fails all): the broken upstream in E16 must not reduce `mcp.tools` for the healthy ones — federation's fail-open property proved through the whole stack.
- **AP-P17 e2e** (upstream existence oracle): the narrow principal in E10 sees neither the denied upstream's tools nor its `engine.servers` row.

### 7.5 Image smoke test — `pg/docker/smoke.sql`

Run against the freshly built image in CI:

```sql
CREATE EXTENSION pg_mcp;
CREATE EXTENSION timescaledb; CREATE EXTENSION age; CREATE EXTENSION vector;
CREATE EXTENSION pgcrypto;    CREATE EXTENSION citext; CREATE EXTENSION "uuid-ossp";
CREATE EXTENSION cube;        CREATE EXTENSION pg_trgm; CREATE EXTENSION earthdistance;
SELECT mcp.refresh('definitely_not_a_server');   -- expect SQLSTATE 42704
```

Non-zero exit or an unexpected SQLSTATE fails the image job. This is the check that catches a `PG_MAJOR` mismatch, a missing `.so`, a wrong install path, or an ABI break against the base image.

### 7.6 Packaging test

`test/noizu/mcp/packaging_test.exs` runs `mix hex.build` into a temp dir and asserts no entry in the tarball starts with `pg/`. It also asserts the same for `daemon/`, matching the existing subproject convention.

---

## 8. Compat & rollback

- **No library change.** `mix.exs` version is untouched; the only Elixir additions are a tagged, excluded test file, test support, and one packaging test. Consumers on hex `~> 0.4` are unaffected by this PR.
- **Image rollback**: revert the Terraform `image` value and `terragrunt apply`. Databases that never ran `CREATE EXTENSION pg_mcp` are unaffected. A database that *did* will fail on `pg_mcp` object access until the image returns; `DROP EXTENSION pg_mcp CASCADE` before rolling back avoids that, at the cost of dropping foreign servers and tables.
- **CI rollback**: the workflow is independent; deleting the file removes it with no effect on the Elixir pipeline.
- **Risk watch — failover.** An image roll on an HA TimescaleDB deployment triggers a failover. This is the single most operationally significant line in the series, and it belongs to a routine image bump rather than to anything `pg_mcp` does. The runbook says so explicitly.
- **Risk watch — base image provenance.** We can layer onto the base but cannot currently rebuild it (§9 Q1). A base security patch requires whoever owns that build. This is a pre-existing condition the series inherits and surfaces, not one it creates.
- **Risk watch — pg18.** CI builds pg18 to keep the code honest, but the cluster is pg17 and only pg17 is smoke-tested in an image. A pg18 build passing does not mean a pg18 deployment is supported.

---

## 9. Open questions

1. **Q1 (blocking a production roll, not this PR):** Where does `docker.io/noizu/timescaledb-ha-with-age` get built? Its Dockerfile is not in this workspace. Layering works without it, but a base bump, a CVE patch, or a Postgres minor upgrade needs the source. Someone must name the owning repo before this ships to a cluster.
2. **Q2:** Registry and tag. The proposed tag is `noizu/timescaledb-ha-with-age-mcp:<base>-mcp0.4.0-r1`. Confirm the registry (Docker Hub, per the base) and whether the layered image should live under a different name entirely to avoid implying it is the same artifact lineage.
3. **Q3:** Should the `e2e` CI job run on every PR touching `pg/**`, or only on tags and a nightly? It needs a container plus a Bandit listener plus network between them, which is the slowest and flakiest thing in the workflow. Recommend: on PR for `pg/**`, nightly for everything, with a `[skip-e2e]` escape.
4. **Q4a:** The e2e engine runs stdio upstreams, which means spawning OS processes inside the CI job. The fixture upstreams must therefore be runnable with no network fetch — an escript built in the job, or `elixir -e`, not `npx -y @modelcontextprotocol/...`. Confirm that constraint before the fixture is written; it shapes what the upstreams can be.
5. **Q4:** `PG_MCP_URL` names a Postgres. The e2e suite also needs the *reverse* address — how the container reaches the Bandit listener. `host.docker.internal` works on Docker Desktop and not on Linux CI without `--add-host`. Recommend a second variable, `PG_MCP_CALLBACK_HOST`, defaulting to `host.docker.internal`.
6. **Q5:** Should the extension ship a `pg_mcp` PGXN package or a `.deb` in addition to image layering? ADR-006 says image layering only. Confirm that no consumer outside the Noizu cluster is expected for 0.4.0.
7. **Q6:** The runbook says to check generation DDL into Liquibase. Liquibase targets are declared in `.infra-config.yaml` in the monorepo. Which target owns the `pg_mcp` DDL — each consuming application's changelog, or a new shared one? This is a monorepo decision that lands outside this PR.
