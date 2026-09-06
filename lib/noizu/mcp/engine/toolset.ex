defmodule Noizu.MCP.Engine.Toolset do
  @moduledoc """
  The federation projection (PRD-11 §4.4): one namespaced spec and one
  `%Noizu.MCP.Toolset.Context.Layer{}` per READY upstream, folded by the
  existing merge engine.

  Normative placement: every upstream layer sits at **weight 100** under
  `{:upstream, name}` — below persisted layers (200) and the ACL layer (300) —
  so an operator's override of a federated tool wins and ACL filters it with
  NO federation-specific precedence code (D2). The layers carry the upstream's
  namespaced catalog as their provenance; the specs themselves are read
  per-request from live session state (D3 — no compile capture, no parallel
  tool registry, AP-P14).

  Namespacing is `<server>.<name>` for tools, prompts and resource templates;
  resource URIs gain a `mcp+engine://<server>/` prefix so they stay globally
  unique and reversible.
  """

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Engine.Session
  alias Noizu.MCP.Server.Features
  alias Noizu.MCP.Server.Tool.Spec
  alias Noizu.MCP.Toolset.Layer
  alias Noizu.MCP.Types.{Prompt, Resource, ResourceTemplate, Tool}

  @federation_weight 100
  @reserved_prefix "engine"

  # ── names ──────────────────────────────────────────────────────────────────

  @doc "The namespaced wire name for upstream `server`'s `name`."
  @spec join(String.t(), String.t()) :: String.t()
  def join(server, name), do: server <> "." <> name

  @doc """
  Split a wire name into `{upstream, local}` on the FIRST dot, or `nil` when
  the name has no namespace prefix. `"engine.*"` is the engine's own reserved
  prefix and is reported as such (`{"engine", rest}`) — callers decide.
  """
  @spec split(String.t()) :: {String.t(), String.t()} | nil
  def split(name) when is_binary(name) do
    case String.split(name, ".", parts: 2) do
      [prefix, rest] -> {prefix, rest}
      [_bare] -> nil
    end
  end

  def split(_other), do: nil

  @doc "True when `wire_name` is a federated entry (a prefixed, non-engine name)."
  @spec federated?(String.t()) :: boolean()
  def federated?(wire_name) do
    case split(wire_name) do
      {prefix, _rest} -> prefix != @reserved_prefix
      nil -> false
    end
  end

  # ── resource URIs ──────────────────────────────────────────────────────────

  @doc "The engine-globally-unique URI for upstream `server`'s `uri`."
  @spec resource_uri(String.t(), String.t()) :: String.t()
  def resource_uri(server, uri), do: "mcp+engine://#{server}/#{uri}"

  @doc """
  Reverse a prefixed resource URI to `{server, original_uri}`, or `nil` when
  `uri` is not an engine-federated URI.
  """
  @spec split_resource_uri(String.t()) :: {String.t(), String.t()} | nil
  def split_resource_uri("mcp+engine://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [server, original] -> {server, original}
      _other -> nil
    end
  end

  def split_resource_uri(_other), do: nil

  # ── live sessions ──────────────────────────────────────────────────────────

  @doc "The ready pooled sessions, as `{server_name, pid}`."
  @spec ready_sessions() :: [{String.t(), pid()}]
  def ready_sessions do
    Engine.Supervisor.sessions()
    |> Enum.filter(fn {key, _pid} -> is_binary(key) end)
    |> Enum.map(fn {name, pid} -> {name, pid} end)
  end

  @doc "The session pid for a federated prefix, or nil."
  @spec session_for(String.t()) :: pid() | nil
  def session_for(prefix) do
    case Engine.Supervisor.pooled_pid(prefix) do
      nil -> nil
      pid -> pid
    end
  end

  # ── specs (the base surface fed to the merge engine) ──────────────────────

  @doc """
  The engine's full static spec set for one request (D3): the local
  registration plus every ready upstream's namespaced catalog. A down upstream
  contributes nothing (D5 — an empty layer, never an error).
  """
  @spec specs() :: [Spec.t()]
  def specs do
    Features.Tools.expand(Engine.__mcp__(:tools)) ++ federated_specs()
  end

  defp federated_specs do
    Enum.flat_map(ready_sessions(), fn {name, pid} ->
      {:ok, tools} = Session.catalog(pid)
      Enum.map(prefix_tools(name, tools), &to_spec/1)
    end)
  rescue
    # A session dying mid-read fails ITS catalog entry, not the engine's
    # listing (D5 — set-level failure, never server-level).
    _error -> []
  end

  @doc "Namespace upstream `server`'s tools under its prefix."
  @spec prefix_tools(String.t(), [Tool.t()]) :: [Tool.t()]
  def prefix_tools(server, tools) do
    Enum.map(tools, fn %Tool{} = tool -> %{tool | name: join(server, tool.name)} end)
  end

  # A federated spec carries the namespaced definition with a RAW schema
  # (input_fields nil — field-level override ops are out of scope for remote
  # tools) and dispatches through `Noizu.MCP.Engine.Federated`.
  defp to_spec(%Tool{} = tool) do
    %Spec{
      module: Engine.Federated,
      fun: :call,
      arity: 2,
      definition: tool,
      cast_plan: nil,
      output_schema: tool.output_schema
    }
  end

  # ── layers (the federation context pass) ──────────────────────────────────

  @doc """
  One `%Layer{}` at weight 100 per READY upstream (FR-11.9), folded by the
  existing merge engine together with persisted (200) and ACL (300) layers.
  """
  @spec layers() :: [Layer.t()]
  def layers do
    for {name, _pid} <- ready_sessions() do
      %Layer{id: {:upstream, name}, weight: @federation_weight, ops: []}
    end
  end

  # ── prompts & resources ────────────────────────────────────────────────────

  @doc "Namespaced prompts from every ready upstream."
  @spec prompts() :: [Prompt.t()]
  def prompts do
    Enum.flat_map(ready_sessions(), fn {name, pid} ->
      case Session.surfaces(pid) do
        {:ok, %{prompts: prompts}} -> Enum.map(prompts, &%{&1 | name: join(name, &1.name)})
        _other -> []
      end
    end)
  end

  @doc "Namespaced resources (URI-prefixed) from every ready upstream."
  @spec resources() :: [Resource.t()]
  def resources do
    Enum.flat_map(ready_sessions(), fn {name, pid} ->
      case Session.surfaces(pid) do
        {:ok, %{resources: resources}} ->
          Enum.map(resources, &%{&1 | uri: resource_uri(name, &1.uri)})

        _other ->
          []
      end
    end)
  end

  @doc "Namespaced resource templates (URI-prefixed) from every ready upstream."
  @spec resource_templates() :: [ResourceTemplate.t()]
  def resource_templates do
    Enum.flat_map(ready_sessions(), fn {name, pid} ->
      case Session.surfaces(pid) do
        {:ok, %{resource_templates: templates}} ->
          Enum.map(templates, &%{&1 | uri_template: resource_uri(name, &1.uri_template)})

        _other ->
          []
      end
    end)
  end

  # ── federated sql relations (FR-11.19) ────────────────────────────────────

  @doc """
  The `<server>.<relation>` re-exports of every upstream advertising
  `experimental.sql`, as `sql/schema` relation descriptors (kind `"dataset"`).
  """
  @spec sql_relations() :: [map()]
  def sql_relations do
    Enum.flat_map(ready_sessions(), fn {name, pid} ->
      relations = Session.sql_relations(pid)

      Enum.map(relations, fn relation ->
        Map.update(relation, "name", join(name, relation["name"]), &join(name, &1))
        |> Map.put("kind", "dataset")
        |> Map.put("writable", false)
      end)
    end)
  rescue
    _error -> []
  end
end
