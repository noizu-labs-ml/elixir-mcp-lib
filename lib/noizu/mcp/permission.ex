defmodule Noizu.MCP.Permission.Grant do
  @moduledoc """
  A persisted per-caller policy record (PRD-4 §4.4): one grant of (or denial
  on) a toolset for one principal. Grants are the weight-200 layer the context
  pass folds (PRD-3 §4.2 seam) — they ADJUST or EXTEND the static surface
  (renames, per-tool ops, extra scopes); they never HIDE what the static pass
  shows (visibility gating belongs to ACL at weight 300 — AP-10).

  `id` is host-assigned (uuid/slug) and is the store's primary key: re-put with
  the same id upserts. `subject` must be a JSON scalar (string | integer) —
  persistence stores it as its string form. `tool_overrides` keys are BASE
  canonical names; each op list folds as `%Noizu.MCP.Toolset.Override{}`
  ops at `weight: 200` under `{:persisted, id}`.

  Storage note: the provider JSON-encodes records (`Jason` round-trip is the
  conformance contract) — atoms flatten to strings and are restored on read;
  `expires_at`/`inserted_at` round-trip as ISO8601 strings back into
  `%DateTime{}`.
  """

  @enforce_keys [:id, :toolset_slug, :authenticator, :subject, :effect]
  defstruct [
    :id,
    :toolset_slug,
    :authenticator,
    :subject,
    :effect,
    scopes: [],
    tool_overrides: %{},
    expires_at: nil,
    inserted_at: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          toolset_slug: String.t(),
          authenticator: String.t() | atom(),
          subject: String.t() | integer(),
          effect: :allow | :deny,
          scopes: [String.t()],
          tool_overrides: %{optional(String.t()) => [Noizu.MCP.Toolset.Override.t()]},
          expires_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          metadata: map()
        }
end

defmodule Noizu.MCP.Permission.Negotiation do
  @moduledoc """
  A persisted consent record (PRD-4 §4.4): one tool on one toolset that needs
  a scope conversation before it may run. A negotiation is SATISFIED for a
  caller when `granted == true` OR `required_scopes` are covered by the
  caller's effective scopes (`Principal.granted_scopes` ∪ allow-grant scopes);
  satisfied AND granted ⇒ `metadata_overrides` fold onto the tool's effective
  `_meta` (consent artifacts such as elevation URIs ride here — PRD-5 §5
  depends on the field); satisfied-but-ungranted ⇒ callable.

  Unsatisfied negotiations keep the tool VISIBLE but `callable: false` with
  `reason: {:negotiation_required, missing_scopes}` — consent flows need the
  client to see the tool to request scopes (Q2). Resolving such an entry is the
  ONE honest `:forbidden` path (PRD-1's existence-hiding `invalid_params`
  remains the rule for ACL-hidden/absent tools).

  Multiple negotiations for one tool: most recent `inserted_at` wins (store
  list order is `inserted_at desc` — provider conformance case).
  """

  @enforce_keys [:id, :toolset_slug, :authenticator, :tool]
  defstruct [
    :id,
    :toolset_slug,
    :authenticator,
    :tool,
    required_scopes: [],
    granted: false,
    metadata_overrides: %{},
    expires_at: nil,
    inserted_at: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          toolset_slug: String.t(),
          authenticator: String.t() | atom(),
          tool: String.t(),
          required_scopes: [String.t()],
          granted: boolean(),
          metadata_overrides: %{optional(String.t()) => term()},
          expires_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          metadata: map()
        }
end

defimpl Jason.Encoder, for: Noizu.MCP.Permission.Grant do
  # PRD §4.4 sketches `@derive Jason.Encoder`; the derive cannot carry this
  # record because DateTime has no Jason encoding and effect/op atoms flatten.
  # The explicit impl is the derive-equivalent: field-for-field, with
  # datetimes as ISO8601 strings and atoms as their string forms — the exact
  # shape the persistence providers store (shared with the encode pipeline on
  # Noizu.MCP.Persistence so the two never drift).
  def encode(grant, opts) do
    Jason.Encoder.encode(Noizu.MCP.Permission.grant_map(grant), opts)
  end
end

defimpl Jason.Encoder, for: Noizu.MCP.Permission.Negotiation do
  # See the Grant impl note — same derive-equivalent, same shared pipeline.
  def encode(negotiation, opts) do
    Jason.Encoder.encode(Noizu.MCP.Permission.negotiation_map(negotiation), opts)
  end
end

defmodule Noizu.MCP.Permission do
  @moduledoc false
  # The storage-map builders behind the two record Jason impls and the
  # persistence encode pipeline (PRD-4 §4.1: records are JSON-encoded by the
  # provider; atoms flatten to strings, datetimes become ISO8601).

  alias Noizu.MCP.Permission.{Grant, Negotiation}
  alias Noizu.MCP.Toolset.Override

  @doc false
  # ⟦𓎼𓂋𓄿𓈖𓏏⟧ grant_map :: auto-generated pointer for public function grant_map
  def grant_map(%Grant{} = grant) do
    %{
      "id" => grant.id,
      "toolset_slug" => grant.toolset_slug,
      "authenticator" => scalar(grant.authenticator),
      "subject" => scalar(grant.subject),
      "effect" => grant.effect && Atom.to_string(grant.effect),
      "scopes" => grant.scopes,
      "tool_overrides" => ops_map(grant.tool_overrides),
      "expires_at" => iso(grant.expires_at),
      "inserted_at" => iso(grant.inserted_at),
      "metadata" => grant.metadata
    }
  end

  @doc false
  # ⟦𓎼𓂋𓄿𓈖𓏏⟧ negotiation_map :: auto-generated pointer for public function negotiation_map
  def negotiation_map(%Negotiation{} = negotiation) do
    %{
      "id" => negotiation.id,
      "toolset_slug" => negotiation.toolset_slug,
      "authenticator" => scalar(negotiation.authenticator),
      "tool" => negotiation.tool,
      "required_scopes" => negotiation.required_scopes,
      "granted" => negotiation.granted,
      "metadata_overrides" => negotiation.metadata_overrides,
      "expires_at" => iso(negotiation.expires_at),
      "inserted_at" => iso(negotiation.inserted_at),
      "metadata" => negotiation.metadata
    }
  end

  # JSON scalars (PRD §4.4): strings stay, integers stringify (the store
  # columns are text — one normalization, applied by every provider, is what
  # keeps the two adapters fork-free), atoms stringify, everything else is the
  # caller's problem and surfaces as an encode failure on put.
  defp scalar(v) when is_binary(v), do: v
  defp scalar(v) when is_integer(v), do: Integer.to_string(v)
  defp scalar(v) when is_atom(v) and v != nil, do: Atom.to_string(v)
  defp scalar(v), do: v

  defp ops_map(overrides) when is_map(overrides) do
    Map.new(overrides, fn {name, ops} when is_binary(name) ->
      {name, Enum.map(List.wrap(ops), &op_map/1)}
    end)
  end

  defp op_map(%Override{} = op), do: Override.to_map(op)

  # Structs (host-authored ops as plain maps) pass through for the provider's
  # validation to flag; Jason encodes whatever it can.
  defp op_map(other), do: other

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
