# pg/docker — the pg_mcp image layer

Layer the compiled `pg_mcp` extension onto a Postgres image (PRD-10 §4.1,
ADR-001/002/006). Distribution is image layering — not hex, not PGXN — so the
artifact is a `.so` plus control and SQL files installed into the image's
`pkglibdir` and `sharedir`, and nothing else.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | builder (pgrx 0.19.2 against PGDG headers) → runtime (artifacts only) |
| `smoke.sql` | base-agnostic smoke test: `CREATE EXTENSION pg_mcp` + the `42704` probe |
| `smoke-production.sql` | §7.5 full smoke: also creates every extension the pinned Noizu base ships |
| `e2e-compose.yaml` | stands up the `postgres:17` profile the Elixir e2e suite expects |

## Build

From the repository root (the build context is the repo, the Dockerfile path
is `pg/docker/Dockerfile`):

```bash
# local dev profile — stock postgres:17, no Noizu registry needed:
docker build -f pg/docker/Dockerfile \
  --build-arg BASE_IMAGE=postgres:17 --build-arg FINAL_USER=root .

# production profile — layers onto the pinned cluster base (uid 1000):
docker build -f pg/docker/Dockerfile .
```

`ARG PG_MAJOR` (default 17) must match the base image's major — the builder
links against that major's PGDG headers, and the smoke test catches any
mismatch at build-verification time, not in production. The runtime stage
resolves the real install directories from the base image's own `pg_config`;
nothing hardcodes `/usr/lib/postgresql/17/…`.

The extension is **not** added to `shared_preload_libraries` (D5 fail-open per
server). It loads on `CREATE EXTENSION`; a database that never creates it is
unaffected.

### Builder libc caveat

The builder is Debian (glibc). The pinned production base is the same family
today; if that base ever moves to musl (alpine), the builder base must move
with it. The nightly production smoke test in `.github/workflows/pg_mcp.yml`
is the tripwire for exactly this class of drift.

## Smoke test

```bash
docker run -d --rm --name pg_mcp_smoke -e POSTGRES_PASSWORD=postgres \
  <the-built-image>
sleep 5   # or poll pg_isready
docker exec -i pg_mcp_smoke psql -U postgres -v ON_ERROR_STOP=1 < pg/docker/smoke.sql
```

`smoke.sql` passes on any base. `smoke-production.sql` additionally creates
every extension the pinned Noizu base must keep shipping (timescaledb, age,
vector, pgcrypto, citext, uuid-ossp, cube, pg_trgm, earthdistance — FR-10.3)
and only makes sense on that base.

## The e2e one-liner

```bash
docker compose -f pg/docker/e2e-compose.yaml up -d --build
PG_MCP_URL=ecto://postgres:postgres@localhost:15432/pg_mcp_e2e mix test --only pg_mcp
```

The compose file builds the `postgres:17` profile and uses **host
networking**: the container shares the host loopback, so Postgres reaches the
host-side Bandit listener at `http://localhost:<port>/mcp` — which is also
what keeps that URL inside the extension's plaintext-http loopback rule
(SEC-4); `host.docker.internal` would be a non-loopback http URL and is
refused at `CREATE SERVER`, by design. Postgres listens on host port **15432**
(kept clear of a host Postgres). The suite is excluded by default; with
`PG_MCP_URL` unset, `mix test --only pg_mcp` reports it skipped and exits 0.
`PG_MCP_CALLBACK_HOST` (default `localhost`) names how the container should
reach the host listener.

## Tag scheme

`docker.io/noizu/timescaledb-ha-with-age-mcp:<base>-mcp<extension version>-r<layer revision>`
— e.g. `…:pg17.9-ts2.25.2-all-age1.7.0-mcp0.3.0-r1`. The base provenance stays
legible in the tag. Registry pushes happen only on tag builds in CI (PRs build
and discard).

## Related

* Install runbook for operators: `docs/pg-mcp-install.md`
* Extension build/test (host-side): `pg/README.md`
* CI: `.github/workflows/pg_mcp.yml`
