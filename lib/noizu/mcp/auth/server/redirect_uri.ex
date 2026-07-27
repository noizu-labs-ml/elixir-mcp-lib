defmodule Noizu.MCP.Auth.Server.RedirectURI do
  @moduledoc """
  Redirect-URI validation and matching (RFC 6749 §3.1.2, RFC 8252, OAuth 2.1).

  Matching is **exact string comparison** with exactly one carve-out, and the
  carve-out is forced on us: `http://127.0.0.1:PORT/callback` for a native
  client (RFC 8252 §7.3). Claude Code and Codex bind an *ephemeral* loopback
  port, so the port they register can never be the port they come back on. For
  loopback redirect URIs the port is therefore ignored, and only the port —
  scheme, host and path still have to match byte-for-byte.

      iex> registered = ["http://127.0.0.1/callback", "https://claude.ai/api/mcp/auth_callback"]
      iex> Noizu.MCP.Auth.Server.RedirectURI.matches?("http://127.0.0.1:53821/callback", registered)
      true
      iex> Noizu.MCP.Auth.Server.RedirectURI.matches?("http://127.0.0.1:53821/other", registered)
      false

  Everything else that makes redirect matching go wrong is refused up front:
  no fragment (RFC 6749 forbids one, and it is where an appended `?error=`
  hides), no userinfo (`https://claude.ai@evil.example`), no wildcards, and
  `http` only for loopback.

  ## Host suffix matching

  `host_allowed?/2` — used to constrain what a dynamically-registered client may
  register — matches a host exactly or as a subdomain **on a label boundary**.
  Naive `String.ends_with?/2` accepts `evil-claude.ai` for `claude.ai`, which
  hands an attacker a valid-looking registration:

      iex> Noizu.MCP.Auth.Server.RedirectURI.host_allowed?("evil-claude.ai", ["claude.ai"])
      false
      iex> Noizu.MCP.Auth.Server.RedirectURI.host_allowed?("api.claude.ai", ["claude.ai"])
      true
  """

  @loopback_hosts ["127.0.0.1", "::1", "[::1]", "localhost"]

  @type error ::
          :invalid_redirect_uri
          | :insecure_scheme
          | :fragment_not_allowed
          | :userinfo_not_allowed
          | :host_not_allowed

  @doc """
  Validate a redirect URI as registered or as presented at the authorization
  endpoint.

  Options:

    * `:allowed_hosts` — when set, the URI's host must satisfy
      `host_allowed?/2`. This is the DCR guard (`MCP_DCR_ALLOWED_REDIRECT_HOSTS`);
      loopback URIs are exempt, since a native client's loopback callback is not
      a host anyone can claim.
    * `:allow_custom_scheme` — permit a private-use scheme (`com.example.app:/cb`,
      RFC 8252 §7.1). Default `false`.
    * `:allow_http_hosts` — extra hosts allowed over plain `http` (a
      development-only escape hatch). Default `[]`.
  """
  @spec validate(term(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def validate(uri, opts \\ [])

  def validate(uri, opts) when is_binary(uri) and uri != "" do
    parsed = URI.parse(uri)

    cond do
      not is_nil(parsed.fragment) -> {:error, :fragment_not_allowed}
      not is_nil(parsed.userinfo) -> {:error, :userinfo_not_allowed}
      String.contains?(uri, "*") -> {:error, :invalid_redirect_uri}
      is_nil(parsed.scheme) -> {:error, :invalid_redirect_uri}
      true -> validate_scheme(uri, parsed, opts)
    end
  end

  def validate(_uri, _opts), do: {:error, :invalid_redirect_uri}

  @doc "True when the URI passes `validate/2`."
  @spec valid?(term(), keyword()) :: boolean()
  def valid?(uri, opts \\ []), do: match?({:ok, _}, validate(uri, opts))

  @doc """
  True when `requested` matches one of the client's `registered` URIs.

  Exact comparison, except that a loopback URI's port is ignored (see the
  module doc). Neither side is normalized beyond that: case-folding a path or
  dropping a trailing slash here would silently widen every registration.
  """
  @spec matches?(term(), [String.t()] | String.t()) :: boolean()
  def matches?(requested, registered) when is_binary(registered),
    do: matches?(requested, [registered])

  def matches?(requested, registered) when is_binary(requested) and is_list(registered) do
    Enum.any?(registered, &equal?(requested, &1))
  end

  def matches?(_requested, _registered), do: false

  @doc """
  Resolve which registered URI a request matched, or `{:error, :invalid_redirect_uri}`.

  A request with **no** `redirect_uri` resolves to the client's single
  registered URI, and is an error when the client registered more than one —
  guessing between them is how a code lands at the wrong callback.
  """
  @spec resolve(String.t() | nil, [String.t()]) ::
          {:ok, String.t()} | {:error, :invalid_redirect_uri}
  def resolve(nil, [only]), do: {:ok, only}
  def resolve(nil, _registered), do: {:error, :invalid_redirect_uri}

  def resolve(requested, registered) when is_binary(requested) do
    if matches?(requested, registered),
      do: {:ok, requested},
      else: {:error, :invalid_redirect_uri}
  end

  def resolve(_requested, _registered), do: {:error, :invalid_redirect_uri}

  @doc "True for a loopback redirect URI, whose port is matched loosely."
  @spec loopback?(term()) :: boolean()
  def loopback?(uri) when is_binary(uri), do: loopback_host?(URI.parse(uri).host)
  def loopback?(_uri), do: false

  @doc """
  Match a host against an allowlist: exact, or a subdomain on a label boundary.
  """
  @spec host_allowed?(String.t() | nil, [String.t()]) :: boolean()
  def host_allowed?(host, allowed) when is_binary(host) and is_list(allowed) do
    host = String.downcase(host)

    Enum.any?(allowed, fn entry ->
      entry = entry |> String.downcase() |> String.trim_leading("*.")
      host == entry or String.ends_with?(host, "." <> entry)
    end)
  end

  def host_allowed?(_host, _allowed), do: false

  defp validate_scheme(uri, parsed, opts) do
    scheme = String.downcase(parsed.scheme)

    cond do
      scheme == "https" -> validate_host(uri, parsed, opts)
      scheme == "http" and loopback_host?(parsed.host) -> validate_host(uri, parsed, opts)
      scheme == "http" and parsed.host in Keyword.get(opts, :allow_http_hosts, []) -> {:ok, uri}
      scheme in ["http", "https"] -> {:error, :insecure_scheme}
      # A private-use scheme has no authority to check.
      Keyword.get(opts, :allow_custom_scheme, false) and String.contains?(scheme, ".") -> {:ok, uri}
      true -> {:error, :invalid_redirect_uri}
    end
  end

  defp validate_host(uri, parsed, opts) do
    cond do
      is_nil(parsed.host) or parsed.host == "" ->
        {:error, :invalid_redirect_uri}

      loopback_host?(parsed.host) ->
        {:ok, uri}

      true ->
        case Keyword.get(opts, :allowed_hosts) do
          nil -> {:ok, uri}
          allowed -> if host_allowed?(parsed.host, allowed), do: {:ok, uri}, else: {:error, :host_not_allowed}
        end
    end
  end

  defp equal?(requested, registered) do
    a = URI.parse(requested)
    b = URI.parse(registered)

    cond do
      requested == registered ->
        true

      loopback_host?(a.host) and loopback_host?(b.host) ->
        # Port-agnostic, everything else exact. Note `localhost` and `127.0.0.1`
        # are still different hosts — a client gets back what it registered.
        scheme(a) == scheme(b) and a.host == b.host and path(a) == path(b) and a.query == b.query

      true ->
        false
    end
  end

  defp loopback_host?(host) when is_binary(host), do: String.downcase(host) in @loopback_hosts
  defp loopback_host?(_host), do: false

  defp scheme(%URI{scheme: nil}), do: nil
  defp scheme(%URI{scheme: scheme}), do: String.downcase(scheme)

  # RFC 8252 registrations are commonly written without a path; `/` and "" are
  # the same request path on the wire, so they compare equal here and nowhere
  # else.
  defp path(%URI{path: nil}), do: "/"
  defp path(%URI{path: ""}), do: "/"
  defp path(%URI{path: path}), do: path
end
