defmodule Noizu.MCP.Auth.Principal do
  @moduledoc """
  The typed request identity (PRD-2): who the caller is, how they
  authenticated, and what scopes they hold.

  The struct is HOST-OWNED — `subject` and `authenticator` are opaque to the
  library, which never constructs a "system" or trusted principal (there is no
  `system/0`; a missing principal is simply anonymous, `nil` on
  `%Noizu.MCP.Ctx{}` — no elevated/implicit identity exists).

  Principals reach handlers through:

    * `Noizu.MCP.Server.Session.deliver/3` — per-request claims, resolved via
      the server's `principal:` opt (or the built-in claims mapping);
    * the `:mcp_principal` assign — a ready principal folded in by the HTTP
      plug at initialize (see the plug's assigns merge) or set out-of-band via
      `Noizu.MCP.Server.Session.put_principal/2`.

  Scope checks use exact match or a trailing-`*` prefix glob (`"pm:*"` matches
  every `pm:` scope; `*` matches every granted scope).
  """

  @enforce_keys [:subject, :authenticator]
  defstruct [
    :subject,
    :authenticator,
    :token_id,
    claims: %{},
    granted_scopes: MapSet.new(),
    metadata: %{}
  ]

  @type subject :: term()
  @type authenticator :: atom()

  @type t :: %__MODULE__{
          subject: subject(),
          authenticator: authenticator(),
          token_id: term() | nil,
          claims: map(),
          granted_scopes: MapSet.t(String.t()),
          metadata: map()
        }

  @doc """
  True when there is no principal. `nil` is the anonymous identity — the ONLY
  way to be anonymous, and never synthesized by the library.
  """
  @spec anonymous?(t() | nil) :: boolean()
  # ⟦𓂷𓊽𓆑𓅓⟧ anonymous? :: True when there is no principal.
  def anonymous?(nil), do: true
  def anonymous?(%__MODULE__{}), do: false

  @doc """
  True when the principal holds `scope`: exact match, or trailing-`*` prefix
  glob (`"pm:*"` matches any scope starting `pm:`; a bare `*` matches any
  granted scope). A principal holding no scopes matches only empty-prefix
  globs — i.e. nothing.
  """
  @spec has_scope?(t(), String.t()) :: boolean()
  # ⟦𓋴𓎛𓂋𓆓⟧ has_scope? :: True when the principal holds `scope`.
  def has_scope?(%__MODULE__{granted_scopes: scopes}, scope) when is_binary(scope) do
    cond do
      String.ends_with?(scope, "*") ->
        prefix = binary_part(scope, 0, byte_size(scope) - 1)
        Enum.any?(scopes, &String.starts_with?(&1, prefix))

      true ->
        MapSet.member?(scopes, scope)
    end
  end

  @doc "The granted scopes as a list (unordered)."
  @spec scope_list(t()) :: [String.t()]
  # ⟦𓎝𓋹𓊪𓏏⟧ scope_list :: The granted scopes as a list (unordered).
  def scope_list(%__MODULE__{granted_scopes: scopes}), do: MapSet.to_list(scopes)
end
