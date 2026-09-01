defprotocol Noizu.MCP.Toolset do
  @moduledoc """
  The single toolset resolution path (D1): `tools/list`, `tools/call`, and the
  catalog tool all consume listing/dispatch through this protocol, and every
  implementation materializes the *effective* tool surface (definitions after
  overrides) before validation and wire-rendering (D2).

  Participants are explicit (D4) — there is no semantic `Any` fallback:

    * a server module (`use Noizu.MCP.Server`) — atoms wrap into
      `%Noizu.MCP.Toolset.Ref{}` and delegate to the module's behaviour
      functions;
    * `%Noizu.MCP.Toolset.Ref{}` — delegates to its target module;
    * structs that `use Noizu.MCP.Toolset.Behaviour` and define an explicit
      `defimpl Noizu.MCP.Toolset, for: MyStruct` delegating to the module's
      behaviour functions (see `%Noizu.MCP.Toolset.Static{}`).

  Note: `@derive Noizu.MCP.Toolset` is NOT a supported opt-in — derive
  generates delegation to the protocol's `Any` impl, and the `Any` impl here is
  deliberately fail-closed (D4), so a derived struct would raise on every call.

  Everything else raises `ArgumentError` via the fail-closed `Any` impl. There
  is no runtime exported-function probing anywhere in the dispatch path; a
  target that lacks the behaviour functions raises `UndefinedFunctionError`,
  which call sites (`Features.Tools.protocol_list/protocol_call`) normalize to
  `{:error, %Noizu.MCP.Error{}}` — that toolset is disabled, the server stays
  healthy (D5).
  """

  @fallback_to_any true

  @doc """
  Enumerate the effective tool entries for this toolset under ctx.

  Returns `{:ok, [%Noizu.MCP.Toolset.Entry{}], catalog_version :: String.t()}`
  or `{:error, %Noizu.MCP.Error{}}`. Visibility filtering for the wire happens
  in the callers; hidden tools are entries with `visible: false, callable: true`.
  """
  @spec catalog(t(), ctx :: term(), opts :: keyword()) ::
          {:ok, [Noizu.MCP.Toolset.Entry.t()], String.t()} | {:error, Noizu.MCP.Error.t()}
  def catalog(toolset, ctx, opts)

  @doc """
  Resolve one tool by wire name to its effective form.

  Returns `{:ok, %Noizu.MCP.Toolset.Effective{}}` or
  `{:error, %Noizu.MCP.Error{reason: :invalid_params}}`. A non-callable entry
  resolves to the SAME error as an absent tool (identical message) to avoid a
  discovery oracle for hidden tools.
  """
  @spec resolve(t(), name :: term(), ctx :: term(), opts :: keyword()) ::
          {:ok, Noizu.MCP.Toolset.Effective.t()} | {:error, Noizu.MCP.Error.t()}
  def resolve(toolset, name, ctx, opts)

  @doc """
  Invoke a resolved effective tool: validate/cast against the effective
  schema+plan, arity-dispatch, normalize. Returns whatever the handler returns
  (normalized `ToolResult` / `{:error, %Noizu.MCP.Error{}}` / raised).
  """
  @spec invoke(
          t(),
          Noizu.MCP.Toolset.Effective.t(),
          args :: term(),
          ctx :: term(),
          opts :: keyword()
        ) ::
          term()
  def invoke(toolset, effective, args, ctx, opts)

  @doc """
  Permission projection: `{:ok, %{tools: [%{name, visible, callable}], version}}`
  or `{:error, %Noizu.MCP.Error{}}`.
  """
  @spec permissions(t(), ctx :: term(), opts :: keyword()) ::
          {:ok,
           %{
             tools: [%{name: String.t(), visible: boolean(), callable: boolean()}],
             version: String.t()
           }}
          | {:error, Noizu.MCP.Error.t()}
  def permissions(toolset, ctx, opts)

  @doc """
  Descriptive metadata: `{:ok, %{slug: String.t(), title: String.t() | nil,
  description: String.t() | nil, version: String.t()}}` or
  `{:error, %Noizu.MCP.Error{}}`.
  """
  @spec metadata(t(), ctx :: term(), opts :: keyword()) ::
          {:ok,
           %{
             slug: String.t(),
             title: String.t() | nil,
             description: String.t() | nil,
             version: String.t()
           }}
          | {:error, Noizu.MCP.Error.t()}
  def metadata(toolset, ctx, opts)

  @doc """
  Coerce a toolset entity reference into a dispatchable toolset value: a module
  atom wraps into `%Noizu.MCP.Toolset.Ref{}`; refs and behaviour-backed struct
  participants pass through; anything else raises `ArgumentError`.
  """
  @spec coerce(t() | module()) :: Noizu.MCP.Toolset.Ref.t()
  def coerce(toolset)
end

defmodule Noizu.MCP.Toolset.Entry do
  @moduledoc """
  One effective tool entry as enumerated by `Noizu.MCP.Toolset.catalog/3`.

  Hidden-but-callable state is explicit here (`visible: false, callable: true,
  reason: :hidden_by_spec`) — the dispatch layer finds tools the listing layer
  suppressed, but now first-class instead of as a listing-time filter.
  """

  @enforce_keys [:definition]
  defstruct [
    :definition,
    :input_schema,
    :cast_plan,
    visible: true,
    callable: true,
    reason: nil
  ]

  @type t :: %__MODULE__{
          definition: Noizu.MCP.Types.Tool.t(),
          input_schema: map(),
          cast_plan: list() | nil,
          visible: boolean(),
          callable: boolean(),
          reason: term()
        }
end

defmodule Noizu.MCP.Toolset.Effective do
  @moduledoc """
  A tool resolved to its effective form — the triple `invoke/5` validates,
  casts, and executes against (never the static spec).
  """

  @enforce_keys [:name, :entry, :spec]
  defstruct [
    :name,
    :entry,
    :spec,
    provenance: nil,
    version: nil,
    reason: nil
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          entry: Noizu.MCP.Toolset.Entry.t(),
          spec: Noizu.MCP.Server.Tool.Spec.t(),
          provenance: %{optional(atom()) => {term(), integer()}} | nil,
          version: String.t() | nil,
          reason: term()
        }
end

defimpl Noizu.MCP.Toolset, for: Any do
  @moduledoc false
  # Fail-closed Any impl (D4, documented deviation): it provides NO semantic
  # fallback and cannot make a non-participant dispatchable — it exists solely
  # so `coerce/1` and the semantic calls produce the specified error type
  # instead of a Protocol.UndefinedError.
  @raise_msg "toolset entities must implement Noizu.MCP.Toolset explicitly (derive the protocol or use Noizu.MCP.Toolset.Behaviour)"

  def coerce(_toolset), do: raise(ArgumentError, @raise_msg)
  def catalog(_toolset, _ctx, _opts), do: raise(ArgumentError, @raise_msg)
  def resolve(_toolset, _name, _ctx, _opts), do: raise(ArgumentError, @raise_msg)
  def invoke(_toolset, _effective, _args, _ctx, _opts), do: raise(ArgumentError, @raise_msg)
  def permissions(_toolset, _ctx, _opts), do: raise(ArgumentError, @raise_msg)
  def metadata(_toolset, _ctx, _opts), do: raise(ArgumentError, @raise_msg)
end
