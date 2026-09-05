# Authorization (PRD-2)

## Protocol

`Noizu.MCP.ACL` is a binary-verdict authorization protocol:

    check(subject, resource, action, ctx, opts) :: :allow | :deny

There is no third verdict. Subjects are explicit protocol participants
(D4): `%Noizu.MCP.Auth.Principal{}` consults the server-configured
provider — `use Noizu.MCP.Server, acl: ...` or per-call `opts[:acl]`.
**No provider ⇒ `:allow`**: the seam is inert for unconfigured hosts
(zero-change back-compat). Any other subject type raises via a
deliberately fail-closed `Any` implementation.

## Policy seam

The library owns no policy. Hosts implement the `ACL.Provider`
behaviour; built-ins ship only for the two trivial policies:
`:deny_all` and `:disabled` (allows everything).

Enforcement runs through `filter_entries/4` — the chokepoint inside
the toolset behaviour defaults, which fans out `check_all/5`. Calling
a feature shim directly cannot bypass it. Ungoverned resource kinds
raise at rule time (§4.7).

## Record layer (PRD-4 interplay)

`Noizu.MCP.Permission` defines the persisted records that ride the
toolset merge as **weight-200 layers**:

- `%Grant{}` — per-caller allow/deny: JSON-scalar `subject`, `effect`,
  `scopes`, and `tool_overrides` keyed by base canonical names, folding
  as `Toolset.Override` ops under `{:persisted, id}`. Host-assigned
  `id` is the store key (upsert).
- `%Negotiation{}` — per-tool consent. Satisfied = `granted: true`, or
  required scopes covered by the caller's effective scopes;
  satisfied+granted folds `metadata_overrides` onto tool `_meta`
  (PRD-5 elevation URIs ride here). Multiple records: most recent
  `inserted_at` wins.

Explicit `Jason.Encoder` implementations (not `@derive` — DateTime and
atom handling) share the Persistence encode pipeline, so wire shape and
stored shape cannot drift.

## Verdict semantics

- **ACL denial is silent**: the tool is hidden from listings and calls
  resolve to the identical error as an absent tool (anti-oracle — no
  discovery of hidden surface).
- **Unsatisfied negotiation is visible**: the tool stays listed with
  `callable: false, reason: {:negotiation_required, missing}`; invoking
  it is the single honest `:forbidden` path.
- Layering (AP-10): grants adjust/extend the static surface (weight
  200); they never hide — visibility gating is ACL's job (weight 300).
