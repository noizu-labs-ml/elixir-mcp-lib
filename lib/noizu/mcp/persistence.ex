defmodule Noizu.MCP.Persistence do
  @moduledoc """
  The persistence contract (PRD-4 §4.1) for lib-owned toolset state: DB-defined
  toolsets, per-caller grants, and consent negotiations, across the `"toolsets"`,
  `"toolset_grants"`, `"toolset_negotiations"` store keys — plus `"engine_servers"`
  (PRD-11), the `Noizu.MCP.Engine` upstream registry.

  Three providers ship: `Noizu.MCP.Persistence.Memory` (public ETS, the
  default), `Noizu.MCP.Persistence.Disabled` (the `:disabled` alias — every
  call is `{:error, :persistence_disabled}`, a POLICY of no persisted layers,
  not an outage), and `Noizu.MCP.Persistence.Ecto` (raw SQL over the lib-owned
  tables shipped by `Noizu.MCP.Migrations.V1Toolsets`). A host may implement
  its own; the shared conformance suite (`test/support/persistence_conformance_case.ex`)
  is the single source of provider truth (AP-8) — a provider claims support by
  passing that battery, not by implementing callbacks.

  ## Contracts

    * **Expiry is a store invariant.** A record with `expires_at <= at` is
      excluded by EVERY provider, on `get` and `list` (`list/3`'s filter may
      carry `:at`, default now). Callers never re-implement expiry.
    * **JSON round-trip.** Records are lib structs / normalized maps; providers
      JSON-encode on write and restore on read. Atoms flatten to strings and
      are restored (effect, op names, the toolsets store's `base` module —
      `String.to_existing_atom` with a `{:error, {:unknown_base, name}}`
      fallback); datetimes round-trip as ISO8601.
    * **Subjects are JSON scalars.** `string | integer` — normalized to the
      string form on write by every provider (the store columns are text), so
      filters compare normalized. Anything else is `{:error, {:invalid_subject,
      subject}}` on put.
    * **Upsert by id.** `put/4` with an existing id replaces. `delete/4` is
      idempotent. `version/2` is a monotonic per-store string that bumps on
      every write (put AND delete) and feeds catalog_version / cache keys —
      Store-driven bumps rotate a toolset's composed version without any
      record read.
    * **Filter** keys are exact-match terms per store (`%{toolset_slug: s,
      authenticator: a, subject: subj, tool: t, ...}`); a filter key the
      record kind lacks excludes the record. `:authenticator`/`:subject`
      compare string-normalized (atom vs string authenticators match).
    * **`list/3` order is `inserted_at desc`** — the negotiation "most recent
      wins" rule reads straight off list order.

  ## Selection & precedence (§4.3, normative)

  `resolved/2` resolves the provider governing a call, lazily, in this order:

    1. explicit `opts[:providers][:persistence]` or `opts[:persistence]`
       (`providers:` WINS over individual keys when both are present);
    2. the per-server resolution stashed by `Noizu.MCP.Server.Supervisor`
       at init (`:persistent_term` `{server, :persistence}`);
    3. Application env — READ AT CALL TIME (D3): `Application.get_env(:noizu_mcp,
       :providers)[:persistence]` or `Application.get_env(:noizu_mcp, :persistence)`;
    4. the default `:memory`.

  Value shapes everywhere: `:memory | :disabled | Provider | {Provider, opts}`.
  """

  @store_keys ["toolsets", "toolset_grants", "toolset_negotiations", "engine_servers"]

  @type store_key :: String.t()
  @type opts :: keyword()

  @callback put(store_key(), id :: String.t(), record :: map() | struct(), opts()) ::
              :ok | {:error, term()}

  @callback get(store_key(), id :: String.t(), opts()) ::
              {:ok, record :: map() | struct()} | :error | {:error, term()}

  @doc """
  Filter keys: exact-match terms per store plus `:at` (DateTime, default now)
  — records with `expires_at <= at` are EXCLUDED by every provider (expiry is
  a store invariant, not caller logic).
  """
  @callback list(store_key(), filter :: map() | nil, opts()) ::
              {:ok, [record :: map() | struct()]} | {:error, term()}

  @callback delete(store_key(), id :: String.t(), opts()) :: :ok | {:error, term()}

  @doc "Monotonic per-store version string feeding catalog_version / cache keys."
  @callback version(store_key(), opts()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Liveness/table check. Optional — the default is a `version/2` roundtrip on
  `"toolsets"`. Built-in shape: `:ok | {:error, {:tables_missing, [names]}}`
  (`Ecto`, at supervisor boot — a config error must not boot, D4).
  """
  @callback ping(opts()) :: :ok | {:error, term()}

  @optional_callbacks ping: 1

  # ── store keys ────────────────────────────────────────────────────────────

  @doc "The three store keys (§4.1)."
  # ⟦𓋴𓏏𓂋𓅱⟧ store_keys :: The three store keys (§4.1).
  @spec store_keys() :: [String.t()]
  def store_keys, do: @store_keys

  @doc ":ok when `key` is a store key, else `{:error, {:unknown_store_key, key}}`."
  # ⟦𓎼𓅱𓄿𓂋𓂧⟧ guard_store_key :: :ok when `key` is a store key, else `{:error, {:unknown_store_key, key}}`.
  @spec guard_store_key(term()) :: :ok | {:error, {:unknown_store_key, term()}}
  def guard_store_key(key) when key in @store_keys, do: :ok
  def guard_store_key(key), do: {:error, {:unknown_store_key, key}}

  # ── selection (§4.3) ──────────────────────────────────────────────────────

  @doc """
  The provider for a call with no server context (§4.3): explicit opts, then
  Application env (call time), then `:memory`. See `resolved/2` for the full
  chain including the per-server stash.
  """
  # ⟦𓂋𓅱𓋴𓍯𓃭𓆑⟧ resolved :: The provider for a call with no server context (§4.3).
  @spec resolved(opts()) :: {module(), opts()} | nil
  def resolved(opts) when is_list(opts), do: resolved(opts[:server], opts)

  @doc """
  The persistence provider governing this call (§4.3, lazy — D3): explicit
  `opts[:providers][:persistence]` (the combined form wins when present) >
  explicit `opts[:persistence]` > the per-server persistent_term stash (when
  `server` names a started server) > Application env at CALL time (combined
  form, then individual) > `:memory`. Used by Store, the Context pass, and
  direct `Toolset` calls without a session.
  """
  # ⟦𓂋𓅱𓋴𓍯𓃭𓆑⟧ resolved :: The persistence provider governing this call (§4.3, lazy — D3).
  @spec resolved(server :: term(), opts()) :: {module(), opts()} | nil
  def resolved(server, opts) when is_list(opts) do
    case combined(opts[:providers]) || opts[:persistence] || server_stash(server) ||
           combined(Application.get_env(:noizu_mcp, :providers)) ||
           Application.get_env(:noizu_mcp, :persistence) do
      nil -> {Noizu.MCP.Persistence.Memory, []}
      value -> normalize(value)
    end
  end

  def resolved(_server, _opts), do: {Noizu.MCP.Persistence.Memory, []}

  @doc """
  Normalize a selection value shape: `:memory | :disabled | Provider |
  {Provider, opts}` → `{provider, opts}`. `:disabled` resolves to the
  `Disabled` provider (the alias lives HERE, §4.2); unvalidated shapes
  resolve `nil` (the use-time validator is the config gate; this is the
  back-compat floor — same posture as `Noizu.MCP.ACL.Provider`).
  """
  # ⟦𓂋𓄿𓊪⟧ normalize :: Normalize a selection value shape.
  @spec normalize(term()) :: {module(), opts()} | nil
  def normalize(:memory), do: {Noizu.MCP.Persistence.Memory, []}
  def normalize(:disabled), do: {Noizu.MCP.Persistence.Disabled, []}

  def normalize({module, provider_opts}) when is_atom(module) and is_list(provider_opts),
    do: {module, provider_opts}

  def normalize(module) when is_atom(module) and module != nil, do: {module, []}
  def normalize(_other), do: nil

  @doc """
  False ONLY for the `Disabled` provider (§4.2: a policy of no persisted
  layers, not an outage — the context pass skips silently) and unresolvable
  values. Every other provider is enabled, and its failures are D5 outages.
  """
  # ⟦𓊂𓈖𓄿𓃭⟧ enabled? :: False ONLY for the `Disabled` provider (§4.2).
  @spec enabled?({module(), opts()} | nil) :: boolean()
  def enabled?({Noizu.MCP.Persistence.Disabled, _}), do: false
  def enabled?({provider, _}) when is_atom(provider) and provider != nil, do: true
  def enabled?(_other), do: false

  # The supervisor stashed `{server, :persistence}` at init (§4.3); a server
  # that never started simply has no row.
  defp server_stash(server) when is_atom(server) and server != nil,
    do: :persistent_term.get({server, :persistence}, nil)

  defp server_stash(_server), do: nil

  # The combined `providers:` form: WINS over the individual key when present
  # (§4.3); its value (or its absence of the :persistence key) falls through
  # to the next source in the chain.
  defp combined(providers) when is_list(providers),
    do: Keyword.get(providers, :persistence)

  defp combined(_other), do: nil

  # ── ping (optional callback, D4 boot check) ───────────────────────────────

  @doc """
  Dispatch `ping/1` against `provider`, normalizing the miss to the DEFAULT
  impl — a `version/2` roundtrip on `"toolsets"` (house style: direct call,
  rescue only the expected UndefinedFunctionError; no exported probing).
  """
  # ⟦𓊪𓇋𓈖𓎼⟧ ping :: Dispatch `ping/1` against `provider`, normalizing the miss to the DEFAULT.
  @spec ping(module(), opts()) :: :ok | {:error, term()}
  def ping(provider, opts) when is_atom(provider) and is_list(opts) do
    provider.ping(opts)
  rescue
    e in UndefinedFunctionError ->
      if e.module == provider and e.function == :ping and e.arity == 1 do
        case provider.version("toolsets", opts) do
          {:ok, _version} -> :ok
          {:error, _} = error -> error
        end
      else
        reraise e, __STACKTRACE__
      end
  end

  # ── record codec (shared by every provider — AP-8: one semantic pipeline) ─

  @toolset_fields [
    :slug,
    :title,
    :description,
    :base,
    :immutable,
    :include,
    :exclude,
    :tools,
    :metadata
  ]
  @grant_fields [
    :id,
    :toolset_slug,
    :authenticator,
    :subject,
    :effect,
    :scopes,
    :tool_overrides,
    :expires_at,
    :inserted_at,
    :metadata
  ]
  @negotiation_fields [
    :id,
    :toolset_slug,
    :authenticator,
    :tool,
    :required_scopes,
    :granted,
    :metadata_overrides,
    :expires_at,
    :inserted_at,
    :metadata
  ]

  # PRD-11: the engine's upstream registry. Operator-writable columns only —
  # the derived columns (status, last_seen, tool_count, ...) are live session
  # state, never persisted.
  @engine_server_fields [:name, :transport, :command, :url, :auth_ref, :enabled]

  @doc """
  Encode `record` for storage (§4.1): validate + normalize into the store's
  field map, stamp `inserted_at` (provider-on-put when the record carries
  none), then JSON. Returns `{:ok, json, fields, meta}` where `fields` is the
  normalized field map (column-binding source for structured stores) and
  `meta` carries the `expires_at`/`inserted_at` the provider needs for the
  store invariant without re-decoding — or `{:error, term()}`.

  Shared by Memory, Ecto and any host provider — the conformance suite is the
  fork guard (AP-8).
  """
  # ⟦𓂋𓈖𓎡𓍯𓂧𓅱⟧ encode_record :: Encode `record` for storage (§4.1).
  @spec encode_record(store_key(), map() | struct()) ::
          {:ok, String.t(), fields :: map(),
           %{expires_at: DateTime.t() | nil, inserted_at: DateTime.t()}}
          | {:error, term()}
  def encode_record(store_key, record) do
    with :ok <- guard_store_key(store_key),
         {:ok, fields} <- normalize_record(store_key, record) do
      json = Jason.encode!(fields)

      {:ok, json, fields, %{expires_at: fields[:expires_at], inserted_at: fields[:inserted_at]}}
    end
  rescue
    e in [Jason.EncodeError, Protocol.UndefinedError, ArgumentError] ->
      {:error, {:encode_failed, Exception.message(e)}}
  end

  @doc """
  Restore one stored `json` payload to its record (struct for lib kinds —
  `%Noizu.MCP.Toolset.Custom{}`, `%Noizu.MCP.Permission.Grant{}`,
  `%Noizu.MCP.Permission.Negotiation{}`). `{:error, {:unknown_base, name}}`
  when a stored toolset's base module atom no longer exists (§4.4).
  """
  # ⟦𓂧𓅱𓎡𓍯𓂧𓅱⟧ decode_record :: Restore one stored `json` payload to its record.
  @spec decode_record(store_key(), String.t()) :: {:ok, map() | struct()} | {:error, term()}
  def decode_record(store_key, json) when is_binary(json) do
    with :ok <- guard_store_key(store_key) do
      revive_record(store_key, Jason.decode!(json))
    end
  rescue
    e in [Jason.DecodeError, ArgumentError] -> {:error, {:decode_failed, Exception.message(e)}}
  end

  @doc false
  # The revive step proper — shared by decode_record/2 (blob stores) and by
  # structured stores that read COLUMNS and rebuild the string-keyed raw map.
  # ⟦𓂋𓅂𓆑⟧ revive_record :: The revive step proper — shared by decode_record/2 (blob stores) and by.
  @spec revive_record(store_key(), map()) :: {:ok, map() | struct()} | {:error, term()}
  def revive_record(store_key, raw) when is_map(raw) do
    with :ok <- guard_store_key(store_key) do
      revive(store_key, raw)
    end
  end

  @doc "The store invariant (§4.1): `expires_at <= at` ⇒ expired."
  # ⟦𓊋𓊪𓇋𓂋⟧ expired? :: The store invariant (§4.1).
  @spec expired?(map() | struct(), DateTime.t()) :: boolean()
  def expired?(%{expires_at: nil}, _at), do: false

  def expired?(%{expires_at: %DateTime{} = expires_at}, at),
    do: DateTime.compare(expires_at, at) != :gt

  @doc """
  Exact-match filter (§4.1): every filter key must equal the record's field —
  `:at` is the expiry anchor the provider consumed already; `:subject` and
  `:authenticator` compare string-normalized (atom callers match string
  records); a filter key the record kind lacks excludes the record.
  """
  # ⟦𓅓𓄿𓏏𓎡𓉔⟧ match_filter? :: Exact-match filter (§4.1).
  @spec match_filter?(map() | struct(), map() | nil) :: boolean()
  def match_filter?(_record, filter) when filter in [nil, %{}], do: true

  def match_filter?(record, filter) when is_map(filter) do
    Enum.all?(filter, fn
      {:at, _at} -> true
      {key, value} -> record_field(record, key) |> normalized?(key, value)
    end)
  end

  def match_filter?(_record, _other), do: false

  # ── encode internals ──────────────────────────────────────────────────────

  defp normalize_record("toolsets", %Noizu.MCP.Toolset.Custom{} = toolset) do
    normalize_toolset(Map.from_struct(toolset))
  end

  defp normalize_record("toolsets", %{} = record),
    do: normalize_toolset(normalize_fields(record, @toolset_fields))

  defp normalize_record("toolset_grants", %Noizu.MCP.Permission.Grant{} = grant),
    do: normalize_grant(Map.from_struct(grant))

  defp normalize_record("toolset_grants", %{} = record),
    do: normalize_grant(normalize_fields(record, @grant_fields))

  defp normalize_record(
         "toolset_negotiations",
         %Noizu.MCP.Permission.Negotiation{} = negotiation
       ),
       do: normalize_negotiation(Map.from_struct(negotiation))

  defp normalize_record("toolset_negotiations", %{} = record),
    do: normalize_negotiation(normalize_fields(record, @negotiation_fields))

  defp normalize_record("engine_servers", %{} = record) do
    fields = normalize_fields(record, @engine_server_fields)

    with :ok <- required(fields, :name),
         :ok <- transport_valid?(fields.transport) do
      {:ok,
       %{
         name: fields.name,
         transport: to_string(fields.transport),
         command: fields.command,
         url: fields.url,
         auth_ref: fields.auth_ref,
         enabled: !!fields.enabled,
         # Store invariants (§4.1): every record carries its insert stamp; the
         # registry has no expiry.
         expires_at: nil,
         inserted_at: DateTime.utc_now()
       }}
    end
  end

  defp normalize_record(store_key, other) do
    {:error, {:invalid_record, store_key, other}}
  end

  defp transport_valid?(t) when t in ["stdio", "http", :stdio, :http], do: :ok

  defp transport_valid?(other), do: {:error, {:invalid_transport, other}}

  defp normalize_toolset(record) do
    with :ok <- required(record, :slug),
         {:ok, base} <- base_string(record[:base]) do
      fields = normalize_fields(record, @toolset_fields)

      {:ok,
       %{
         slug: fields.slug,
         title: fields.title,
         description: fields.description,
         base: base,
         immutable: !!fields.immutable,
         include: fields.include,
         exclude: List.wrap(fields.exclude || []),
         tools: tools_map(fields.tools),
         metadata: fields.metadata || %{},
         inserted_at: now_unless(Map.get(record, :inserted_at)),
         updated_at: DateTime.utc_now()
       }}
    end
  end

  defp normalize_grant(record) do
    with :ok <- required(record, :id),
         :ok <- required(record, :toolset_slug),
         :ok <- required(record, :subject),
         {:ok, subject} <- subject_scalar(record[:subject]),
         {:ok, effect} <- effect_atom(record[:effect]) do
      fields = normalize_fields(record, @grant_fields)

      {:ok,
       %{
         id: fields.id,
         toolset_slug: fields.toolset_slug,
         authenticator: scalar(fields.authenticator),
         subject: subject,
         effect: effect,
         scopes: List.wrap(fields.scopes || []),
         tool_overrides: ops_map(fields.tool_overrides),
         expires_at: fields.expires_at,
         inserted_at: now_unless(fields.inserted_at),
         metadata: fields.metadata || %{}
       }}
    end
  end

  defp normalize_negotiation(record) do
    with :ok <- required(record, :id),
         :ok <- required(record, :toolset_slug),
         :ok <- required(record, :tool) do
      fields = normalize_fields(record, @negotiation_fields)

      {:ok,
       %{
         id: fields.id,
         toolset_slug: fields.toolset_slug,
         authenticator: scalar(fields.authenticator),
         tool: fields.tool,
         required_scopes: List.wrap(fields.required_scopes || []),
         granted: !!fields.granted,
         metadata_overrides: fields.metadata_overrides || %{},
         expires_at: fields.expires_at,
         inserted_at: now_unless(fields.inserted_at),
         metadata: fields.metadata || %{}
       }}
    end
  end

  # Pull the known fields off a normalized (atom-keyed) map — a plain map may
  # carry string keys, so coerce them against the known set first.
  defp normalize_fields(record, fields) do
    by_atom = Map.new(fields, fn field -> {Atom.to_string(field), field} end)

    Map.new(fields, fn field ->
      value = Map.get(record, field) || Map.get(record, by_atom[Atom.to_string(field)])
      {field, value}
    end)
  end

  defp required(record, field) do
    if record[field] in [nil, ""],
      do: {:error, {:missing_field, field}},
      else: :ok
  end

  # §4.4: subjects must be JSON scalars — string | integer (normalized to the
  # string form); anything else is a put error.
  defp subject_scalar(subject) when is_binary(subject), do: {:ok, subject}
  defp subject_scalar(subject) when is_integer(subject), do: {:ok, Integer.to_string(subject)}
  defp subject_scalar(subject), do: {:error, {:invalid_subject, subject}}

  defp effect_atom(:allow), do: {:ok, :allow}
  defp effect_atom(:deny), do: {:ok, :deny}
  defp effect_atom("allow"), do: {:ok, :allow}
  defp effect_atom("deny"), do: {:ok, :deny}
  defp effect_atom(other), do: {:error, {:invalid_effect, other}}

  # `%Custom{}` bases store as module-name STRINGS; on read they restore via
  # `String.to_existing_atom` (:unknown_base fallback). Nested `%Custom{}`
  # bases are NOT storable in 0.3.0 (D4 — the lib never chases slug chains).
  defp base_string(base) when is_atom(base) and base != nil, do: {:ok, Atom.to_string(base)}
  defp base_string(base) when is_binary(base), do: {:ok, base}

  defp base_string(other), do: {:error, {:unsupported_base, other}}

  defp tools_map(tools) when tools in [%{}, nil], do: %{}

  defp tools_map(tools) when is_map(tools) do
    Map.new(tools, fn
      {name, ops} when is_binary(name) ->
        {name, Enum.map(List.wrap(ops), &op_map/1)}

      _other ->
        []
    end)
    |> Map.reject(fn {_name, ops} -> ops == [] end)
  end

  defp tools_map(_other), do: %{}

  defp ops_map(overrides) when overrides in [%{}, nil], do: %{}

  defp ops_map(overrides) when is_map(overrides) do
    Map.new(overrides, fn
      {name, ops} when is_binary(name) ->
        {name, Enum.map(List.wrap(ops), &op_map/1)}

      _other ->
        []
    end)
    |> Map.reject(fn {_name, ops} -> ops == [] end)
  end

  defp ops_map(_other), do: %{}

  defp op_map(%Noizu.MCP.Toolset.Override{} = op), do: Noizu.MCP.Toolset.Override.to_map(op)
  defp op_map(%{} = op), do: normalize_op_map(op)
  defp op_map(other), do: other

  # Plain-map ops (host-authored) normalize to the storage shape; a foreign
  # op name raises ArgumentError at ENCODE time (to_existing_atom), surfacing
  # as {:error, {:encode_failed, _}} — loud, never stored.
  defp normalize_op_map(%{} = op) do
    %{
      "op" => op_name(op[:op] || op["op"]),
      "target" => op[:target] || op["target"],
      "value" => op[:value] || op["value"],
      "tool" => op[:tool] || op["tool"],
      "inherit?" => !!(op[:inherit?] || op["inherit?"])
    }
  end

  defp op_name(name) when is_atom(name) and name != nil, do: Atom.to_string(name)
  defp op_name(name) when is_binary(name), do: String.to_existing_atom(name) |> Atom.to_string()

  defp scalar(v) when is_atom(v) and v != nil, do: Atom.to_string(v)
  defp scalar(v) when is_binary(v), do: v
  defp scalar(v) when is_integer(v), do: Integer.to_string(v)
  defp scalar(nil), do: nil

  defp now_unless(nil), do: DateTime.utc_now()
  defp now_unless(%DateTime{} = dt), do: dt

  # ── decode internals ──────────────────────────────────────────────────────

  defp revive("toolsets", raw) do
    with {:ok, base} <- restore_base(raw["base"]) do
      {:ok,
       %Noizu.MCP.Toolset.Custom{
         slug: raw["slug"],
         title: raw["title"],
         description: raw["description"],
         base: base,
         immutable: !!raw["immutable"],
         include: raw["include"],
         exclude: raw["exclude"] || [],
         tools: revive_tools(raw["tools"]),
         metadata: raw["metadata"] || %{}
       }}
    end
  end

  defp revive("toolset_grants", raw) do
    {:ok,
     %Noizu.MCP.Permission.Grant{
       id: raw["id"],
       toolset_slug: raw["toolset_slug"],
       authenticator: raw["authenticator"],
       subject: raw["subject"],
       effect: restore_atom(raw["effect"]),
       scopes: raw["scopes"] || [],
       tool_overrides: revive_tools(raw["tool_overrides"]),
       expires_at: restore_dt(raw["expires_at"]),
       inserted_at: restore_dt(raw["inserted_at"]),
       metadata: raw["metadata"] || %{}
     }}
  end

  defp revive("toolset_negotiations", raw) do
    {:ok,
     %Noizu.MCP.Permission.Negotiation{
       id: raw["id"],
       toolset_slug: raw["toolset_slug"],
       authenticator: raw["authenticator"],
       tool: raw["tool"],
       required_scopes: raw["required_scopes"] || [],
       granted: !!raw["granted"],
       metadata_overrides: raw["metadata_overrides"] || %{},
       expires_at: restore_dt(raw["expires_at"]),
       inserted_at: restore_dt(raw["inserted_at"]),
       metadata: raw["metadata"] || %{}
     }}
  end

  defp revive("engine_servers", raw) do
    {:ok,
     %{
       "name" => raw["name"],
       "transport" => raw["transport"],
       "command" => raw["command"],
       "url" => raw["url"],
       "auth_ref" => raw["auth_ref"],
       "enabled" => !!raw["enabled"]
     }}
  end

  defp revive(store_key, _raw), do: {:error, {:unknown_store_key, store_key}}

  defp restore_base(nil), do: {:error, {:unknown_base, nil}}

  defp restore_base(base) when is_binary(base) do
    {:ok, String.to_existing_atom(base)}
  rescue
    ArgumentError -> {:error, {:unknown_base, base}}
  end

  defp restore_atom(nil), do: nil
  defp restore_atom(name) when is_binary(name), do: String.to_existing_atom(name)

  defp restore_dt(nil), do: nil

  defp restore_dt(iso) when is_binary(iso) do
    {:ok, dt, _offset} = DateTime.from_iso8601(iso)
    dt
  end

  defp revive_tools(nil), do: %{}

  defp revive_tools(tools) when is_map(tools) do
    Map.new(tools, fn {name, ops} -> {name, Enum.map(List.wrap(ops), &revive_op/1)} end)
  end

  defp revive_op(%{} = op), do: Noizu.MCP.Toolset.Override.from_map(op)

  # ── filter internals ──────────────────────────────────────────────────────

  defp record_field(record, key) do
    value = Map.get(record, key)
    if value == nil and not Map.has_key?(record, key), do: :__missing__, else: value
  end

  # `:subject`/`:authenticator` compare string-normalized (§4.4: JSON-scalar
  # subjects store stringified; authenticators arrive as atoms or strings).
  defp normalized?(:__missing__, _key, _value), do: false

  defp normalized?(record_value, key, filter_value) when key in [:subject, :authenticator],
    do: comparable(record_value) == comparable(filter_value)

  defp normalized?(record_value, _key, filter_value), do: record_value == filter_value

  defp comparable(v) when is_binary(v), do: v
  defp comparable(v) when is_integer(v), do: Integer.to_string(v)
  defp comparable(v) when is_atom(v) and v != nil, do: Atom.to_string(v)
  defp comparable(v), do: v
end
