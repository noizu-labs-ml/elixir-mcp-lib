defmodule Noizu.MCP.RenderCtx do
  @moduledoc """
  Render context threaded through every description render site.

  A `%RenderCtx{}` carries the knobs that tailor how tool/field descriptions are
  resolved for a given caller: the requested `verbosity` (0–9), and — as seams
  for later work (spec §3) — an optional `runner` and `model`. `defaults` holds
  the resolved default chain (annotation < server < deployment/global), used when
  no explicit verbosity is supplied.

      %Noizu.MCP.RenderCtx{
        verbosity: 0..9 | nil,     # nil ⇒ resolve via the defaults chain
        runner:    atom | nil,     # e.g. :codex, :grok, :claude (not yet consulted)
        model:     atom | String.t() | nil,
        defaults:  %{verbosity: 5}
      }

  `default/0` yields the zero-config context (verbosity resolves to the built-in
  `5`). Existing call sites that render descriptions without a context use it, so
  single-string tools render exactly as before.

  `effective_verbosity/1` resolves a context's verbosity to a concrete `0..9`
  level via the defaults chain. Note that a description's own annotation-level
  default verbosity (`default_verbosity:`) slots *between* an explicit
  `verbosity` and these defaults — that step lives in
  `Noizu.MCP.Description.resolve/2`, which owns the annotation value.
  """

  @default_verbosity 5

  @type t :: %__MODULE__{
          verbosity: 0..9 | nil,
          runner: atom() | nil,
          model: atom() | String.t() | nil,
          defaults: %{optional(:verbosity) => integer()}
        }

  defstruct verbosity: nil,
            runner: nil,
            model: nil,
            defaults: %{verbosity: @default_verbosity}

  @doc "The zero-config render context (verbosity resolves to the built-in default)."
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc "The built-in default verbosity (`5`) used when nothing else applies."
  @spec default_verbosity() :: 0..9
  def default_verbosity, do: @default_verbosity

  @doc """
  Resolve this context's verbosity to a concrete `0..9` level.

  Explicit `verbosity` wins; otherwise the `defaults.verbosity` chain applies;
  otherwise the built-in `5`. Out-of-domain values are clamped to `0..9`.
  """
  @spec effective_verbosity(t()) :: 0..9
  def effective_verbosity(%__MODULE__{verbosity: v}) when is_integer(v), do: clamp(v)
  def effective_verbosity(%__MODULE__{defaults: %{verbosity: v}}) when is_integer(v), do: clamp(v)
  def effective_verbosity(%__MODULE__{}), do: @default_verbosity

  @doc """
  Resolve the server/global default-verbosity chain into a `defaults` map.

  Precedence: the server module's `use Noizu.MCP.Server, default_verbosity: N`
  option > the `:noizu_mcp, :default_verbosity` application env > the built-in
  `5`. Feeds `RenderCtx.defaults` when a context is built from session assigns.
  """
  @spec server_defaults(module() | term()) :: %{verbosity: 0..9}
  def server_defaults(server) when is_atom(server) and not is_nil(server) do
    %{verbosity: resolve_default_verbosity(server)}
  end

  def server_defaults(_), do: %{verbosity: @default_verbosity}

  defp resolve_default_verbosity(server) do
    cond do
      is_integer(v = server_opt(server, :default_verbosity)) -> clamp(v)
      is_integer(v = Application.get_env(:noizu_mcp, :default_verbosity)) -> clamp(v)
      true -> @default_verbosity
    end
  end

  defp server_opt(server, key) do
    # `Code.ensure_loaded/1` first: `function_exported?/3` reports false for a
    # not-yet-loaded module, which would silently drop a configured default.
    with {:module, _} <- Code.ensure_loaded(server),
         true <- function_exported?(server, :__mcp__, 1),
         opts when is_list(opts) <- server.__mcp__(:opts) do
      opts[key]
    else
      _ -> nil
    end
  end

  defp clamp(v), do: v |> max(0) |> min(9)
end
