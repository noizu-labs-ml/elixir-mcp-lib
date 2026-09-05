# Toolsets (PRD-1 / PRD-3)

## Single resolution path (D1)

`Noizu.MCP.Toolset` is the one protocol through which every
tool-surface consumer flows:

    catalog/3       # discovery (incl. the built-in catalog tool)
    resolve/4       # materialize the effective surface
    invoke/5        # validate → cast → execute
    permissions/3   # permission projection

There are no side doors: `tools/list`, `tools/call`, and the catalog
tool all go through it. Every implementation materializes the
**effective** surface (post-override) before validation and wire
rendering (D2) — `%Effective{}` is the triple that invoke
validates/casts/executes against, never the static spec.
`%Entry{}` makes **hidden-but-callable** first-class
(`visible: false, callable: true`).

## Participants (D4)

Participants are explicit: server modules (atoms wrap into
`%Toolset.Ref{}`), refs, and behaviour-backed structs with explicit
`defimpl`. `@derive` is not supported and the `Any` implementation is
deliberately fail-closed (raises) — there is no semantic fallback. A
target missing behaviour functions raises `UndefinedFunctionError`,
normalized by call sites to `%Noizu.MCP.Error{}`: that toolset is
disabled, the server stays healthy (D5).

## Composition (PRD-3)

Merge/composition semantics live in the behaviour implementations; the
protocol fixes only the seam. Declarative custom toolsets
(`Toolset.Custom`) define a base surface plus include/exclude. The
weighted merge engine (`Toolset.Merge.fold/2`) folds opinion sets into
specs:

| Layer | Weight | Role |
|-------|--------|------|
| Static base surface | — | toolset's own registration |
| `%Permission.Grant{}` / `%Negotiation{}` | 200 | persisted adjust/extend (never hide) |
| ACL visibility gating | 300 | hide/allow — the policy seam |

Overrides form a closed vocabulary (`Toolset.Override`), materialized
by the pure `Toolset.Overrides` and checked by `Toolset.Validator`
(one structural problem per finding). Composed catalogs may be
memoized in `Toolset.Cache` (ETS) — invalidated by the Store facade on
every persisted write.

**Anti-oracle invariant**: a non-callable entry resolves to the SAME
error as an absent tool (identical message) — hidden tools cannot be
discovered by probing.

## Compile-time validation

`use Noizu.MCP.Server` validates `acl:`, `persistence:`, and
`providers:` options at compile time; malformed declarations are
compile errors, not runtime surprises. The 0.3.0 interfaces
(toolset/ACL/persistence) are **frozen** — changes require an ADR and
a 0.4.0.
