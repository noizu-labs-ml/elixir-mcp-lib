defmodule Noizu.MCP.ACL.Provider do
  @moduledoc """
  The authorization policy seam (PRD-2). The library owns NONE of the policy
  data — providers are the only way policy enters (Decision 2, D4): a host
  registers one with `use Noizu.MCP.Server, acl: MyProvider` (or
  `{MyProvider, opts}`), and every catalog/resolve verdict flows through it.

  ## Contracts

    * `check/5` returns `:allow` or `:deny` — there is no third verdict, and
      anything that is not `:allow` is normalized to `:deny` (D5 fail-closed).
    * `check_all/5` is OPTIONAL — the default impl fans out into `check/5`
      (see `check_all/6`). Providers serving many tools SHOULD override to
      batch; a PDP round-trip per tool does not scale.
    * `supported_kinds/0` is OPTIONAL — defaults to all four built-in kinds
      (`supported_kinds/1`). A check against a kind outside the set RAISES:
      an ungoverned kind is a configuration error, never a silent allow
      (§4.7).

  This module also hosts the enforcement chokepoint and provider resolution
  (`filter_entries/4`, `current_provider/2`) — the PRD places them on
  `Noizu.MCP.ACL`, but Elixir's `defprotocol` cannot define functions with
  bodies, so they live on the Provider module (same contracts, different
  home).
  """

  require Logger

  alias Noizu.MCP.ACL.Resource
  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.Ctx

  @callback check(
              subject :: term(),
              resource :: Resource.t(),
              action :: atom() | String.t(),
              ctx :: term(),
              opts :: keyword()
            ) ::
              :allow | :deny

  @callback check_all(
              subject :: term(),
              resources :: [Resource.t()],
              action :: atom() | String.t(),
              ctx :: term(),
              opts :: keyword()
            ) ::
              %{term() => :allow | :deny}

  @callback supported_kinds() :: [atom()]

  @optional_callbacks check_all: 5, supported_kinds: 0

  # ── provider dispatch ─────────────────────────────────────────────────────

  @doc """
  Dispatch one check against `provider`, normalizing the verdict (anything
  that is not `:allow` denies) and emitting `[:noizu_mcp, :acl, :check]`
  telemetry. Raises `ArgumentError` when the resource kind is outside the
  provider's `supported_kinds/0` — fail-closed config error (§4.7).
  """
  # ⟦𓂀𓋴𓎼𓆗⟧ check :: Dispatch one check against `provider`, normalizing the verdict.
  def check(provider, subject, %Resource{} = resource, action, ctx, opts) do
    ensure_kind!(provider, resource)
    started = System.monotonic_time()

    verdict =
      case provider.check(subject, resource, action, ctx, opts) do
        :allow -> :allow
        _other -> :deny
      end

    :telemetry.execute(
      [:noizu_mcp, :acl, :check],
      %{duration: System.monotonic_time() - started},
      %{provider: provider, verdict: verdict}
    )

    verdict
  end

  @doc """
  Batch entry behind `filter_entries/4`: delegates to the provider's
  `check_all/5` when defined, else the DEFAULT impl — fan out into `check/6`.
  Verdicts are keyed by resource id; a provider may return a subset (missing
  ids deny downstream). Extra ids are stale policy, not an error — ignored,
  with a `[:noizu_mcp, :acl, :stale_verdict]` debug event (PRD-2 Q1).
  """
  # ⟦𓋹𓂝𓊪𓎠⟧ check_all :: Batch entry behind `filter_entries/4`.
  def check_all(provider, subject, resources, action, ctx, opts) do
    verdicts = provider_verdicts(provider, subject, resources, action, ctx, opts)

    known = MapSet.new(resources, & &1.id)

    case verdicts |> Map.keys() |> Enum.reject(&MapSet.member?(known, &1)) do
      [] ->
        :ok

      stale ->
        :telemetry.execute([:noizu_mcp, :acl, :stale_verdict], %{}, %{
          provider: provider,
          stale: stale
        })
    end

    verdicts
  end

  # The provider's check_all/5 when defined, else the DEFAULT impl — fan out
  # into check/6. House style (D4/D5): direct call, normalize the
  # UndefinedFunctionError miss — no exported-function probing (PRD-1 §4.1).
  defp provider_verdicts(provider, subject, resources, action, ctx, opts) do
    provider.check_all(subject, resources, action, ctx, opts) || %{}
  rescue
    e in UndefinedFunctionError ->
      if e.module == provider and e.function == :check_all and e.arity == 5 do
        Map.new(resources, fn resource ->
          {resource.id, check(provider, subject, resource, action, ctx, opts)}
        end)
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  The resource kinds `provider` governs: its `supported_kinds/0` when defined,
  else `[:tool, :toolset, :prompt, :resource]` (the §4.6 default — kind-gaps
  surface when prompts/resources gate through ACL in PRD-4).
  """
  # ⟦𓆑𓊽𓄿𓋼⟧ supported_kinds :: The resource kinds `provider` governs.
  def supported_kinds(provider) do
    case provider.supported_kinds() do
      kinds when is_list(kinds) -> kinds
      _other -> [:tool, :toolset, :prompt, :resource]
    end
  rescue
    e in UndefinedFunctionError ->
      if e.module == provider and e.function == :supported_kinds and e.arity == 0 do
        [:tool, :toolset, :prompt, :resource]
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc false
  # ⟦𓎡𓋞𓆤𓂘⟧ ensure_kind! :: auto-generated pointer for public function ensure_kind!
  def ensure_kind!(provider, %Resource{kind: kind}) do
    ensure_kind!(provider, supported_kinds(provider), kind)
  end

  defp ensure_kind!(provider, kinds, kind) do
    unless kind in kinds do
      raise ArgumentError,
            "ACL provider #{inspect(provider)} does not govern resource kind #{inspect(kind)} " <>
              "(supported kinds: #{inspect(kinds)}) — extend supported_kinds/0; refusing to " <>
              "silently allow an ungoverned kind (fail-closed, PRD-2 §4.7)"
    end

    :ok
  end

  # ── provider resolution (per call, D3) ────────────────────────────────────

  @doc """
  The ACL provider governing this call (PRD-2 §4.6 `ACL.current_provider/2`):
  per-call `opts[:acl]`, else the server/toolset's registered
  `__mcp__(:opts)[:acl]`, else `nil` — no provider, inert (back-compat, D4).

  `:disabled` resolves to `nil`; `:deny_all` to the `DenyAll` built-in; a
  `{provider, opts}` form threads `opts` into every check. Returns just the
  module; `resolve_provider/2` carries the check opts.
  """
  # ⟦𓄣𓎛𓋟𓆫⟧ current_provider :: The ACL provider governing this call.
  @spec current_provider(server :: term(), opts :: keyword()) :: module() | nil
  def current_provider(server, opts) do
    case resolve_provider(server, opts) do
      nil -> nil
      {provider, _check_opts} -> provider
    end
  end

  @doc false
  # ⟦𓆐𓊑𓍝𓄁⟧ resolve_provider :: auto-generated pointer for public function resolve_provider
  def resolve_provider(server, opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :acl) ->
        normalize(opts[:acl])

      match?(%Noizu.MCP.Toolset.Static{}, server) ->
        normalize(server.opts[:acl])

      is_atom(server) and server != nil ->
        normalize(server_registration(server))

      true ->
        nil
    end
  end

  def resolve_provider(_server, _opts), do: nil

  # The `acl:` registration of a server/toolset module. Direct call + rescue
  # (house style, D4): a module without `__mcp__/1` or a `:opts` clause has no
  # registration — nil, inert. No exported-function probing.
  defp server_registration(server) do
    server.__mcp__(:opts)[:acl]
  rescue
    _ -> nil
  end

  defp normalize(nil), do: nil
  defp normalize(:disabled), do: nil
  defp normalize(:deny_all), do: {Noizu.MCP.ACL.Providers.DenyAll, []}

  defp normalize({module, check_opts}) when is_atom(module) and is_list(check_opts),
    do: {module, check_opts}

  defp normalize(module) when is_atom(module), do: {module, []}
  # Unvalidated shapes (hosts bypassing `use Noizu.MCP.Server`) resolve inert —
  # the use-time validator is the config gate; this is the back-compat floor.
  defp normalize(_other), do: nil

  # ── enforcement chokepoint ────────────────────────────────────────────────

  @doc """
  THE enforcement chokepoint (PRD-2 §4.6 `ACL.filter_entries/4`): project
  entries through the server's ACL provider, called INSIDE the behaviour
  defaults (catalog / resolve / permissions) so ACL can never be decorative —
  any path through the one resolution path is governed, including the
  `Features.Tools.list_registered/3` / `dispatch/4` shims.

    * no provider ⇒ entries unchanged (inert, back-compat, D4);
    * provider set ⇒ `check_all/5` over `%Resource{kind: :tool, id: name}`
      for every entry; `:deny` or an ABSENT verdict (map miss) sets
      `visible: false, callable: false` with `reason: {:acl, provider}` —
      preserving any existing denial reason;
    * provider RAISE ⇒ every entry denied for this call, logged as a warning
      with `[:noizu_mcp, :acl, :error]` telemetry — the surface fails closed,
      the server stays healthy (D5). Denied tools resolve to the identical
      `invalid_params` error as absent ones; a `supported_kinds` violation
      deliberately RAISES through instead (configuration error).

  The subject is the caller ctx's `auth` principal (`nil` = anonymous — there
  is no system fallback).
  """
  # ⟦𓂝𓎸𓊨𓄢⟧ filter_entries :: THE enforcement chokepoint (PRD-2 §4.6).
  @spec filter_entries(
          [Noizu.MCP.Toolset.Entry.t()],
          server :: term(),
          ctx :: term(),
          opts :: keyword()
        ) ::
          [Noizu.MCP.Toolset.Entry.t()]
  def filter_entries(entries, server, ctx, opts) when is_list(entries) do
    case resolve_for(server, ctx, opts) do
      nil ->
        entries

      {provider, check_opts} ->
        # Every toolset entry is a kind: :tool resource (id = canonical name).
        ensure_kind!(provider, supported_kinds(provider), :tool)

        resources = Enum.map(entries, &%Resource{kind: :tool, id: &1.definition.name})

        verdicts =
          verdicts(provider, subject_for(ctx), resources, ctx, :call, check_opts, entries)

        Enum.map(entries, fn entry ->
          case Map.get(verdicts, entry.definition.name) do
            :allow -> entry
            _other -> deny_entry(entry, provider)
          end
        end)
    end
  end

  # Provider resolution for the enforcement pass. The `Features.Tools.dispatch/4`
  # shim builds a serverless Static — there the caller's ctx carries the
  # governing server, so the ctx registration is the fallback (§4.6: shims
  # route through the same defaults; PRD-2 AP-5).
  defp resolve_for(server, ctx, opts) do
    case resolve_provider(server, opts) do
      nil ->
        ctx_server = if is_map(ctx), do: Map.get(ctx, :server)

        if is_atom(ctx_server) and ctx_server != nil and ctx_server != server do
          resolve_provider(ctx_server, opts)
        else
          nil
        end

      resolved ->
        resolved
    end
  end

  # Provider crash ⇒ deny the set, not the server (D5).
  defp verdicts(provider, subject, resources, ctx, action, check_opts, entries) do
    check_all(provider, subject, resources, action, ctx, check_opts)
  rescue
    e ->
      Logger.warning(
        "ACL provider #{inspect(provider)} raised — denying #{length(entries)} entries: " <>
          Exception.message(e)
      )

      :telemetry.execute([:noizu_mcp, :acl, :error], %{}, %{
        provider: provider,
        entries: length(entries),
        message: Exception.message(e)
      })

      %{}
  end

  defp deny_entry(entry, provider) do
    already_denied? = entry.visible == false or entry.callable == false

    %{
      entry
      | visible: false,
        callable: false,
        reason:
          if(already_denied? and not is_nil(entry.reason),
            do: entry.reason,
            else: {:acl, provider}
          )
    }
  end

  defp subject_for(%Ctx{auth: %Principal{} = principal}), do: principal
  defp subject_for(_ctx), do: nil
end
