defmodule Noizu.MCP.Auth.Server.Upstream do
  @moduledoc """
  How the authorization server authenticates the *human*.

  This facade owns OAuth client and token semantics; it does not own identity.
  Authenticating the end user is delegated to whatever the host already does —
  which for both of our apps is an Authentik OIDC login that already works, with
  sessions, MFA and account recovery already in place. Reimplementing that here
  would be a second, worse login.

  Two implementations ship:

    * `Noizu.MCP.Auth.Server.Upstream.HostSession` — the default. The host tells
      us who is logged in, and where to send someone who isn't.
    * `Noizu.MCP.Auth.Server.Upstream.OIDC` — a self-contained OIDC round trip,
      for a host with no browser session of its own.

  Whatever the implementation, the upstream credential **stops here**. This
  server mints its own tokens for a subject it resolved; it never forwards an
  upstream access token to an MCP client, and never forwards an MCP client's
  token upstream.
  """

  alias Noizu.MCP.Auth.Server.Config

  @typedoc """
  The resolved end user. `subject` is what lands in the access token's `sub`, so
  it must be stable and must be what the host's own authorization checks use.
  """
  @type identity :: %{
          required(:subject) => String.t(),
          optional(:email) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:claims) => map()
        }

  @doc """
  Who is this request from?

    * `{:ok, identity}` — authenticated; the flow continues to consent
    * `{:redirect, url}` — not authenticated; send them here to log in, and they
      come back to the authorization endpoint
    * `{:error, reason}` — cannot tell; the flow renders an error

  Implementations must not treat an inbound `Authorization` header as identity —
  that would make the authorization endpoint accept the very tokens it issues.
  """
  @callback authenticate(conn :: term(), state :: String.t(), Config.t(), opts :: keyword()) ::
              {:ok, identity()} | {:redirect, String.t()} | {:error, term()}

  @doc """
  Handle the upstream's callback, for implementations that run their own round
  trip. `HostSession` does not need this — the host's own callback lands the user
  back on the authorization endpoint with a session.
  """
  @callback callback(conn :: term(), params :: map(), Config.t(), opts :: keyword()) ::
              {:ok, identity(), state :: String.t()} | {:error, term()}

  @optional_callbacks callback: 4

  @doc "Resolve the configured implementation and its options."
  @spec impl(Config.t()) :: {module(), keyword()}
  def impl(%Config{upstream: {module, opts}}), do: {module, opts}

  @doc "Delegate to the configured implementation's `authenticate/4`."
  @spec authenticate(term(), String.t(), Config.t()) ::
          {:ok, identity()} | {:redirect, String.t()} | {:error, term()}
  def authenticate(conn, state, %Config{} = config) do
    {module, opts} = impl(config)
    module.authenticate(conn, state, config, opts)
  end

  @doc "Whether the implementation runs its own callback leg."
  @spec handles_callback?(Config.t()) :: boolean()
  def handles_callback?(%Config{} = config) do
    {module, _opts} = impl(config)
    Code.ensure_loaded?(module) and function_exported?(module, :callback, 4)
  end

  @doc "Delegate to the configured implementation's `callback/4`."
  @spec callback(term(), map(), Config.t()) :: {:ok, identity(), String.t()} | {:error, term()}
  def callback(conn, params, %Config{} = config) do
    {module, opts} = impl(config)
    module.callback(conn, params, config, opts)
  end

  @doc """
  Normalize whatever a host callback returned into an `identity`.

  A bare string is accepted as the subject, since that is what a host bridge
  usually has to hand.
  """
  @spec normalize_identity(term()) :: {:ok, identity()} | :error
  def normalize_identity(subject) when is_binary(subject) and subject != "",
    do: {:ok, %{subject: subject}}

  def normalize_identity(%{subject: subject} = identity)
      when is_binary(subject) and subject != "",
      do: {:ok, identity}

  def normalize_identity(%{"sub" => subject} = claims) when is_binary(subject) and subject != "",
    do: {:ok, %{subject: subject, email: claims["email"], name: claims["name"], claims: claims}}

  def normalize_identity(_other), do: :error
end
