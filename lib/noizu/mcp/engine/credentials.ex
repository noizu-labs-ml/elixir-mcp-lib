defmodule Noizu.MCP.Engine.Credentials do
  @moduledoc """
  `auth_ref` validation and resolution (PRD-11 §4.7).

  An `auth_ref` is a REFERENCE, never a credential. Four forms are valid:

  | Form | Resolution |
  |---|---|
  | `env:VAR` | `System.get_env/1` |
  | `secret:<name>` | the configured `{module, function}` resolver |
  | `infisical:<path>/<KEY>` | the same resolver, Infisical-shaped argument |
  | `passthrough` | the caller's own token (§4.6) |

  **Redaction is structural, not a convention**: resolution happens at connect
  time, the resolved value lives only inside the session that requested it, and
  no return value of this module ever carries it. Errors name the REFERENCE,
  never the value.
  """

  alias Noizu.MCP.Engine.Config

  @schemes ~w(env secret infisical)

  @doc "The valid `auth_ref` forms. `passthrough` is its own form."
  @spec valid_form?(term()) :: boolean()
  def valid_form?("passthrough"), do: true

  def valid_form?(ref) when is_binary(ref) do
    case String.split(ref, ":", parts: 2) do
      [scheme, value] when scheme in @schemes and value != "" -> true
      _other -> false
    end
  end

  def valid_form?(_other), do: false

  @doc "The `invalid_params` message for a rejected `auth_ref` (PRD-11 §4.2)."
  @spec rejection_message(term()) :: String.t()
  def rejection_message(_bad) do
    # The rejected VALUE is deliberately not echoed — it may itself be the
    # credential the caller pasted by mistake (AP-P13).
    "auth_ref must be a reference, never an inline credential. " <>
      "Valid forms: env:VAR, secret:<name>, infisical:<path>/<KEY>, or passthrough. " <>
      "A credential pasted here lands in the query log, pg_stat_activity and the " <>
      "persistence store; keep it in your secret manager and reference it."
  end

  @doc """
  Resolve a stored `auth_ref` to its credential. `passthrough` is resolved by
  the caller (it is per-principal, §4.6) and is an error here.

  Returns `{:ok, credential}` or `{:error, reason}` where `reason` names only
  the reference — the resolved value never appears in any return path.
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, {:unresolved_auth_ref, String.t()}}
  def resolve("env:" <> var) when var != "" do
    case System.get_env(var) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:unresolved_auth_ref, "env:#{var}"}}
    end
  end

  def resolve("secret:" <> _name = ref), do: resolve_via_config(ref)
  def resolve("infisical:" <> _path = ref), do: resolve_via_config(ref)

  def resolve("passthrough"), do: {:error, {:unresolved_auth_ref, "passthrough"}}
  def resolve(ref), do: {:error, {:unresolved_auth_ref, to_string(ref)}}

  defp resolve_via_config(ref) do
    case Config.get(:secret_resolver) do
      {module, fun} when is_atom(module) and is_atom(fun) ->
        case apply(module, fun, [ref]) do
          {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
          _other -> {:error, {:unresolved_auth_ref, ref}}
        end

      _other ->
        {:error, {:unresolved_auth_ref, ref}}
    end
  end

  @doc """
  The pass-through credential for `principal` (§4.6): the host-placed raw token
  convention (`principal.metadata[:raw_token]`, then a `"token"` claim), else
  the principal's subject. A principal that is nil has no credential — the
  engine refuses the call before any upstream request (FR-11.16).
  """
  @spec passthrough_credential(Noizu.MCP.Auth.Principal.t() | nil) ::
          {:ok, String.t()} | :error
  def passthrough_credential(nil), do: :error

  def passthrough_credential(%Noizu.MCP.Auth.Principal{} = principal) do
    principal
    |> credential_candidates()
    |> Enum.find(:error, & &1)
    |> case do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  # First truthy candidate wins; the subject is the last-resort identity.
  defp credential_candidates(principal) do
    candidates = [
      blank_safe(principal.metadata[:raw_token]),
      blank_safe(principal.claims[:token]),
      blank_safe(principal.claims["token"])
    ]

    if is_binary(principal.subject) and principal.subject != "" do
      candidates ++ [{:ok, principal.subject}]
    else
      candidates
    end
  end

  defp blank_safe(value) when is_binary(value) and value != "", do: {:ok, value}
  defp blank_safe(_other), do: false
end
