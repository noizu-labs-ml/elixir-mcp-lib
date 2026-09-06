# pg_mcp — layered PostgreSQL extension image (PRD-10 §4.1, ADR-001/002/006).
#
# Two stages:
#   * builder — compiles the extension with `cargo pgrx package` against the
#     exact PostgreSQL MAJOR of the runtime base (pgrx links each major's
#     headers separately; a MAJOR mismatch is caught by the smoke test, not
#     silently shipped).
#   * runtime — copies ONLY the artifacts (.so + control + SQL scripts) onto
#     BASE_IMAGE. Nothing else leaks in (AC-10.9: delta must stay under 200MB).
#
# Profiles (ADR-006: local dev needs neither the Noizu base nor a registry
# login):
#
#   production (default):
#     docker build -f pg/docker/Dockerfile .
#       → layers onto docker.io/noizu/timescaledb-ha-with-age:pg17.9-…-r2
#       → runs as uid 1000 (FINAL_USER=1000, the base's runtime user)
#   local dev / CI:
#     docker build -f pg/docker/Dockerfile \
#       --build-arg BASE_IMAGE=postgres:17 --build-arg FINAL_USER=root .
#
# The extension is NOT added to shared_preload_libraries (D5 fail-open per
# server): it loads on CREATE EXTENSION; a database that never creates it is
# unaffected. No postgresql.conf change, no restart semantics beyond a normal
# image roll.

# ── global build args ────────────────────────────────────────────────────────
# BASE_IMAGE must be declared in the GLOBAL scope (before the first FROM) so
# the runtime stage's FROM can expand it.
ARG BASE_IMAGE=docker.io/noizu/timescaledb-ha-with-age:pg17.9-ts2.25.2-all-age1.7.0-r2

# ── builder ──────────────────────────────────────────────────────────────────
# Debian bookworm + PGDG: the pinned pgrx 0.19.2 toolchain builds against the
# PGDG headers of the requested major. NOTE: this builder targets glibc bases.
# If the production base ever moves to musl (alpine), the builder base must
# move with it — the production smoke test in CI is the tripwire.
FROM rust:1-bookworm AS builder

ARG PG_MAJOR=17
ARG CARGO_PGRX_VERSION=0.19.2

# PGDG apt repo (bookworm ships only postgresql-15).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      postgresql-${PG_MAJOR} postgresql-server-dev-${PG_MAJOR} \
      clang libclang-dev pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*

RUN cargo install --locked cargo-pgrx@${CARGO_PGRX_VERSION}
# Register the PGDG install (not a pgrx-managed download) as the ${PG_MAJOR}
# toolchain, so `package` links against the same headers the base ships.
RUN cargo pgrx init --pg${PG_MAJOR} $(which pg_config)

WORKDIR /src
# Manifest first for dependency-layer caching, then the crate.
COPY pg/pg_mcp/Cargo.toml pg/pg_mcp/Cargo.lock ./
COPY pg/pg_mcp/pg_mcp.control ./
COPY pg/pg_mcp/src ./src
RUN cargo pgrx package --no-default-features --features pg${PG_MAJOR} \
        --pg-config $(which pg_config) --out-dir /out

# Flatten pgrx's versioned install tree into a layout the runtime stage can
# COPY (COPY --from needs static paths; the real install dirs belong to the
# BASE_IMAGE, so they are resolved THERE from its own pg_config — the literal
# /usr/lib/postgresql/<major>/lib paths in the PRD are asserted, not assumed).
# The find assertions below fail the build on a missing .so or control file.
RUN mkdir -p /artifacts/extension \
 && SO="$(find /out -type f -name 'pg_mcp.so' -print -quit)" \
 && test -n "$SO" || { echo "FATAL: pg_mcp.so not in package output" >&2; exit 1; } \
 && CONTROL="$(find /out -type f -name 'pg_mcp.control' -print -quit)" \
 && test -n "$CONTROL" || { echo "FATAL: pg_mcp.control not in package output" >&2; exit 1; } \
 && install -m 0644 "$SO" /artifacts/pg_mcp.so \
 && find /out -type f -path '*/extension/pg_mcp*' -exec install -m 0644 {} /artifacts/extension/ \; \
 && test -n "$(find /out -type f -path '*/extension/pg_mcp--*.sql' -print -quit)" \
    || { echo "FATAL: no versioned SQL script in package output" >&2; exit 1; }

# ── runtime ──────────────────────────────────────────────────────────────────
FROM ${BASE_IMAGE}

# Re-declared here so the runtime stage can find pg_config on bases that do
# not put it on PATH (the pinned Noizu base keeps it in the versioned bindir).
ARG PG_MAJOR=17
ARG FINAL_USER=1000

USER root
COPY --from=builder /artifacts/pg_mcp.so /tmp/pg_mcp_artifacts/pg_mcp.so
COPY --from=builder /artifacts/extension/ /tmp/pg_mcp_artifacts/extension/

# Install into THIS image's actual pkglibdir/sharedir. Root only for these two
# commands; no runtime process runs as root afterward.
RUN set -eu; \
    PG_CONFIG="$(command -v pg_config || true)"; \
    [ -n "$PG_CONFIG" ] || PG_CONFIG="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"; \
    PKGLIBDIR="$("$PG_CONFIG" --pkglibdir)"; \
    SHAREDIR="$("$PG_CONFIG" --sharedir)"; \
    install -m 0644 /tmp/pg_mcp_artifacts/pg_mcp.so "$PKGLIBDIR/pg_mcp.so"; \
    install -m 0644 /tmp/pg_mcp_artifacts/extension/* "$SHAREDIR/extension/"; \
    rm -rf /tmp/pg_mcp_artifacts

USER ${FINAL_USER}
