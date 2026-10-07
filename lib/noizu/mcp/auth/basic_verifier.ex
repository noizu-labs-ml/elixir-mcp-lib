defmodule Noizu.MCP.Auth.BasicVerifier do
  @moduledoc """
  RFC 7617 HTTP Basic credentials, presented in the `Authorization` header,
  accepted as an MCP credential.

  Where an API key is a bearer token minted by the host, Basic is a username and
  password typed into a client's own credential prompt — curl's `-u`, an HTTP
  client's basic-auth field. The transport plug hands the scheme through
  verbatim, so a mount can serve browsers doing OAuth *and* scripts doing
  `curl -u user:pass` from one verifier chain:

      auth: [
        verifier: {Noizu.MCP.Auth.ChainVerifier, [
          verifiers: [
            {Noizu.MCP.Auth.JWTVerifier, [resource: resource, secret: {MyApp, :secret}]},
            {Noizu.MCP.Auth.BasicVerifier, [
              resource: resource,
              validator: {MyApp.Accounts, :mcp_credentials}
            ]}
          ]
        ]}
      ]

  `MyApp.Accounts.mcp_credentials/2` receives `(username, password)` and answers
  `{:ok, %{scopes: [...], claims: %{...}}}` or `:error`. **Compare the password
  against a hash** — this verifier never sees or stores one, so the strength of
  the scheme is whatever your validator makes it.

  For tests and single-operator deployments a static `:users` map works without
  a validator:

      users: %{"alice" => Noizu.MCP.Auth.Server.Secret.token_hash("s3cret!")}

  Values are `Noizu.MCP.Auth.Server.Secret.token_hash/1` digests (SHA-256 hex),
  compared in constant time. Plain SHA-256 is fine for a high-entropy password
  but not for a human-chosen one at scale — a real user store belongs behind
  `:validator`, where you can run bcrypt or Argon2.

  ## Options

    * `:validator` — `{module, function}`, `{module, function, extra_args}`
      (username and password are prepended), or a 2-arity fun.
    * `:users` — a static `%{username => token_hash}` map (used when `:validator`
      is absent).
    * `:scopes` — scopes granted when the validator did not name any. Written to
      the claims as a space-joined `scope` unless the claims already carry one.
    * `:default_claims` — merged under the built claims (identity claims such
      as `%{"iss" => ...}`; scope never comes from here).
    * `:resource` — canonical resource URI of the mount. Stamped onto the claims
      as `aud` when nothing else set one, exactly as `ApiKeyVerifier` does.
    * `:realm` — the challenge realm advertised by `challenge/1`. Default `"mcp"`.

  Failure is always `{:error, :invalid_token}` — a caller cannot distinguish a
  malformed header from an unknown user from a wrong password.
  """

  @behaviour Noizu.MCP.Auth.TokenVerifier

  alias Noizu.MCP.Auth.Resource
  alias Noizu.MCP.Auth.Server.Secret
  alias Noizu.MCP.Auth.WWWAuthenticate

  @doc """
  The `WWW-Authenticate` challenge a mount should send with a 401 when it wants
  the client's browser (or curl) to prompt for Basic credentials:

      Noizu.MCP.Auth.BasicVerifier.challenge()          # => ~s(Basic realm="mcp")
      Noizu.MCP.Auth.BasicVerifier.challenge(realm: "ops")
  """
  @spec challenge(keyword()) :: String.t()
  def challenge(opts \\ []) do
    WWWAuthenticate.format("Basic", %{"realm" => Keyword.get(opts, :realm, "mcp")})
  end

  @doc """
  Validate a username/password pair against the verifier's credential source —
  the same lookup `verify/3` runs, exposed so `Noizu.MCP.Auth.Server.Upstream.Password`
  and a host's own login form can share one validator.

  Returns `{:ok, %{scopes: [...], claims: %{...}}}` or `{:error, :invalid_credentials}`.
  """
  @spec validate_credentials(String.t(), String.t(), keyword()) ::
          {:ok, %{scopes: [String.t()], claims: map()}} | {:error, :invalid_credentials}
  def validate_credentials(username, password, opts)
      when is_binary(username) and is_binary(password) and is_list(opts) do
    case {Keyword.fetch(opts, :validator), Keyword.fetch(opts, :users)} do
      {{:ok, validator}, _} -> check_validator(validator, username, password)
      {_, {:ok, users}} when is_map(users) -> check_users(users, username, password)
      _ -> {:error, :invalid_credentials}
    end
  end

  def validate_credentials(_username, _password, _opts), do: {:error, :invalid_credentials}

  @impl true
  def verify(token, _conn_info, opts) when is_binary(token) and is_list(opts) do
    with {:ok, username, password} <- parse(token),
         {:ok, granted} <- validate_credentials(username, password, opts) do
      {:ok, stamp(granted, username, opts)}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_token, _conn_info, _opts), do: {:error, :invalid_token}

  # The transport passes `Basic <credentials>` through with the scheme intact;
  # a bare base64 payload is also accepted, for callers that stripped the scheme
  # before handing the header over.
  defp parse(header) do
    encoded =
      case header do
        "Basic " <> rest -> String.trim(rest)
        "basic " <> rest -> String.trim(rest)
        _ -> header
      end

    with {:ok, decoded} <- Base.decode64(encoded),
         [username, password] <- String.split(decoded, ":", parts: 2),
         true <- username != "" do
      {:ok, username, password}
    else
      _ -> :error
    end
  end

  defp check_validator({module, fun}, username, password),
    do: normalize(apply(module, fun, [username, password]))

  defp check_validator({module, fun, args}, username, password),
    do: normalize(apply(module, fun, [username, password | args]))

  defp check_validator(fun, username, password) when is_function(fun, 2),
    do: normalize(fun.(username, password))

  defp check_validator(_validator, _username, _password), do: {:error, :invalid_credentials}

  defp normalize({:ok, %{scopes: scopes, claims: claims}}) when is_list(scopes) and is_map(claims),
    do: {:ok, %{scopes: Enum.map(scopes, &to_string/1), claims: claims}}

  defp normalize({:ok, %{claims: claims}}) when is_map(claims),
    do: {:ok, %{scopes: [], claims: claims}}

  defp normalize({:ok, claims}) when is_map(claims),
    do: {:ok, %{scopes: [], claims: claims}}

  defp normalize(_other), do: {:error, :invalid_credentials}

  # Unknown user or not: the password still travels through the same SHA-256
  # digest and the same constant-time compare, so a wrong username is not
  # measurably faster than a wrong password.
  defp check_users(users, username, password) do
    stored = Map.get(users, username, dummy_hash())
    if Secret.equal?(Secret.token_hash(password), stored), do: {:ok, %{scopes: [], claims: %{}}}, else: {:error, :invalid_credentials}
  end

  defp dummy_hash, do: Secret.token_hash("")

  defp stamp(granted, username, opts) do
    # `:default_claims` fills in behind the credential source — but scope is
    # never one of them; it comes from the source, the `:scopes` default, or
    # not at all.
    defaults = Keyword.get(opts, :default_claims, %{}) |> Map.drop(["scope", "scopes"])
    claims = Map.merge(defaults, granted.claims)
    claims = Map.put_new(claims, "sub", username)
    claims = put_scope(claims, granted.scopes, opts)

    case Keyword.fetch(opts, :resource) do
      {:ok, resource} ->
        case Resource.normalize(resource) do
          {:ok, resource} -> Map.put_new(claims, "aud", resource)
          {:error, :invalid_resource} -> claims
        end

      :error ->
        claims
    end
  end

  defp put_scope(claims, [], opts) do
    case Keyword.get(opts, :scopes, []) do
      [] -> claims
      scopes -> put_scope(claims, scopes, [])
    end
  end

  defp put_scope(claims, scopes, _opts) do
    if Map.has_key?(claims, "scope") or Map.has_key?(claims, "scopes") do
      claims
    else
      Map.put(claims, "scope", Enum.join(scopes, " "))
    end
  end
end
