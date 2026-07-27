defmodule Noizu.MCP.Auth.Resource do
  @moduledoc """
  Canonical resource identifiers (RFC 8707 / RFC 9728).

  An MCP mount's resource URI is the audience its access tokens are bound to.
  Getting the comparison wrong is the whole confused-deputy problem: a token
  minted for `https://host/mcp` must not open `https://host/mcp/learning`.
  So the contract here is **byte-exact matching**, and normalization is
  limited to the handful of transformations the RFCs declare
  scheme-insignificant:

    * scheme lowercased, and restricted to `http`/`https`
    * host lowercased (DNS is case-insensitive)
    * the default port for the scheme dropped

  Everything else is left alone. In particular there is **no trailing-slash
  coercion** — `…/mcp` and `…/mcp/` are different resources, because a client
  that asked for one must not be handed the other, and because the protected
  resource metadata document has to byte-match whatever the user typed.

  Fragments are rejected (RFC 8707 §2 forbids them); a fragment would let two
  distinct strings name one resource.

      iex> Noizu.MCP.Auth.Resource.normalize("HTTPS://App.Example.COM:443/mcp/learning")
      {:ok, "https://app.example.com/mcp/learning"}

      iex> Noizu.MCP.Auth.Resource.equal?("https://x/mcp", "https://x/mcp/")
      false
  """

  @type t :: String.t()
  @type error :: :invalid_resource

  @default_ports %{"http" => 80, "https" => 443}

  @doc """
  Normalize a resource URI, or `{:error, :invalid_resource}` when it is not a
  usable absolute identifier.
  """
  @spec normalize(term()) :: {:ok, t()} | {:error, error()}
  def normalize(resource) when is_binary(resource) do
    uri = URI.parse(resource)
    scheme = uri.scheme && String.downcase(uri.scheme)

    cond do
      scheme not in ["http", "https"] -> {:error, :invalid_resource}
      is_nil(uri.host) or uri.host == "" -> {:error, :invalid_resource}
      not is_nil(uri.fragment) -> {:error, :invalid_resource}
      not is_nil(uri.userinfo) -> {:error, :invalid_resource}
      true -> {:ok, render(uri, scheme)}
    end
  end

  def normalize(_resource), do: {:error, :invalid_resource}

  @doc """
  Normalize or raise. For mount configuration, where a bad resource URI is a
  deployment error that should surface at boot rather than as a silent 401.
  """
  @spec normalize!(term()) :: t()
  def normalize!(resource) do
    case normalize(resource) do
      {:ok, normalized} ->
        normalized

      {:error, :invalid_resource} ->
        raise ArgumentError,
              "invalid canonical resource URI: #{inspect(resource)} — expected an absolute " <>
                "http(s) URI with no fragment and no userinfo"
    end
  end

  @doc "True when both sides normalize to the same canonical URI."
  @spec equal?(term(), term()) :: boolean()
  def equal?(a, b) do
    case {normalize(a), normalize(b)} do
      {{:ok, a}, {:ok, b}} -> a == b
      _ -> false
    end
  end

  @doc """
  True when `resource` equals the single configured resource, or is a member of
  the configured list.

  A list is supported for issuer/mount migrations. It never widens what a token
  reaches — each entry still has to match byte-exactly.
  """
  @spec matches?(term(), t() | [t()]) :: boolean()
  def matches?(resource, allowed) when is_list(allowed),
    do: Enum.any?(allowed, &equal?(resource, &1))

  def matches?(resource, allowed), do: equal?(resource, allowed)

  @doc """
  Build a mount's canonical resource from an issuer origin and a path.

  The issuer is an origin with no path (the design decision that collapses the
  RFC 8414 path-insertion ambiguity), so this is a plain concatenation — the
  path is not rewritten, only required to be absolute.

      iex> Noizu.MCP.Auth.Resource.build("https://app.example.com", "/mcp/learning")
      {:ok, "https://app.example.com/mcp/learning"}
  """
  @spec build(t(), String.t() | nil) :: {:ok, t()} | {:error, error()}
  def build(issuer, path) do
    with {:ok, origin} <- normalize(issuer) do
      case path do
        nil -> {:ok, origin}
        "" -> {:ok, origin}
        "/" <> _ = path -> normalize(origin <> path)
        _ -> {:error, :invalid_resource}
      end
    end
  end

  defp render(uri, scheme) do
    host = String.downcase(uri.host)

    authority =
      case uri.port do
        nil -> host
        port -> if port == @default_ports[scheme], do: host, else: "#{host}:#{port}"
      end

    query = if uri.query in [nil, ""], do: "", else: "?" <> uri.query

    "#{scheme}://#{authority}#{uri.path || ""}#{query}"
  end
end
