if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.PlugSupport do
    @moduledoc """
    Shared plumbing for the authorization-server endpoints: parameter reading,
    client authentication, uniform error rendering, `cache-control: no-store`,
    CORS, and the rate-limit hook.

    Kept in one place because these are the details that go wrong quietly. A
    token response cached by an intermediary, an error page that echoes a
    parameter, a 500 where a `400` was meant — each is a small omission in one
    endpoint and a real hole across five.
    """

    import Plug.Conn
    require Logger

    alias Noizu.MCP.Auth.Server
    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.Errors
    alias Noizu.MCP.Auth.Server.Params

    @doc """
    Normalize plug options into a `Config`.

    `forward` may hand over a keyword list (evaluated at compile time) or an
    already-built `Config`; both work, and building it here means a
    misconfiguration raises at boot rather than on the first request.
    """
    @spec config(term()) :: Config.t()
    def config(%Config{} = config), do: config
    def config(opts) when is_list(opts), do: Server.config(opts)

    @doc """
    Every parameter for this request: query string merged under the body.

    Handles a conn that has been through `Plug.Parsers` and one that has not (a
    bare `Bandit` mount, or a `scope` with no parsers) — the endpoints must work
    either way, since a host that pipes `/oauth` through `:api` gets parsers and
    one that forwards from a bare scope does not.
    """
    @spec read_params(Plug.Conn.t()) :: {:ok, Plug.Conn.t(), map()}
    def read_params(conn) do
      conn = fetch_query_params(conn)

      case conn.body_params do
        %Plug.Conn.Unfetched{} ->
          {conn, body} = parse_body(conn)
          {:ok, conn, Map.merge(conn.query_params, body)}

        parsed when is_map(parsed) ->
          {:ok, conn, Map.merge(conn.query_params, parsed)}
      end
    end

    @doc """
    Client credentials from the request: HTTP Basic first (RFC 6749 §2.3.1
    prefers it), then `client_id`/`client_secret` in the body.

    `{:ok, {client_id, secret_or_nil}}`, or `{:error, %Errors{}}` for a malformed
    Basic header or a request with no `client_id` at all.
    """
    @spec client_credentials(Plug.Conn.t(), map()) ::
            {:ok, {String.t(), String.t() | nil}} | {:error, Errors.t()}
    def client_credentials(conn, params) do
      basic = conn |> get_req_header("authorization") |> List.first()

      with {:ok, credentials} <- Params.basic_credentials(basic) do
        case credentials do
          {client_id, secret} ->
            {:ok, {client_id, secret}}

          nil ->
            with {:ok, client_id} <- Params.fetch(params, "client_id", code: :invalid_client),
                 {:ok, secret} <- Params.optional(params, "client_secret") do
              {:ok, {client_id, secret}}
            end
        end
      end
    end

    @doc """
    A JSON response with `cache-control: no-store`.

    Mandatory on every token, registration and revocation response: a cached
    token response is a credential sitting in a proxy.
    """
    @spec json(Plug.Conn.t(), pos_integer(), map()) :: Plug.Conn.t()
    def json(conn, status, body) do
      conn
      |> no_store()
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    @doc "A JSON response that may be cached (metadata, JWKS)."
    @spec cacheable_json(Plug.Conn.t(), pos_integer(), map(), non_neg_integer()) :: Plug.Conn.t()
    def cacheable_json(conn, status, body, max_age \\ 300) do
      conn
      |> put_resp_header("cache-control", "public, max-age=#{max_age}")
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    @doc """
    A JSON OAuth error response.

    `invalid_client` additionally carries a `WWW-Authenticate` challenge, per
    RFC 6749 §5.2, when the client tried Basic authentication.
    """
    @spec error_json(Plug.Conn.t(), Errors.t()) :: Plug.Conn.t()
    def error_json(conn, %Errors{} = error) do
      log_error(conn, error)

      conn
      |> maybe_challenge(error)
      |> json(error.status, Errors.to_map(error))
    end

    @doc """
    A rendered HTML error — the **only** correct answer at the authorization
    endpoint when the `client_id` is unresolved or the `redirect_uri` is invalid.

    Redirecting in that case would make this endpoint an open redirector, and
    would hand the error (with any `state`) to whoever supplied the URI. Nothing
    from the request is echoed into the page.
    """
    @spec error_page(Plug.Conn.t(), Errors.t()) :: Plug.Conn.t()
    def error_page(conn, %Errors{} = error) do
      log_error(conn, error)

      body = """
      <!DOCTYPE html>
      <html lang="en"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Authorization error</title>
      <style>
        :root { color-scheme: light dark; }
        body { font: 16px/1.5 system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; padding: 0 1rem; }
        code { background: rgba(127,127,127,.18); padding: .1em .35em; border-radius: 3px; }
      </style>
      </head><body>
      <h1>This request could not be authorized</h1>
      <p>#{Errors.description(error)}</p>
      <p><code>#{error.code}</code></p>
      <p>Nothing was granted. Close this window and start again from your client.</p>
      </body></html>
      """

      # A 401 would make the browser pop its own credential dialog, and there is
      # no `WWW-Authenticate` scheme that would satisfy it — the caller is a
      # person looking at a page, not a client with a token.
      status = if error.status == 401, do: 400, else: error.status

      conn
      |> no_store()
      |> put_resp_content_type("text/html")
      |> send_resp(status, body)
    end

    @doc """
    Redirect an error back to an **already-validated** `redirect_uri`, per
    RFC 6749 §4.1.2.1.

    Only call this once `RedirectURI` has matched the URI against the resolved
    client's registrations. `iss` rides along (RFC 9207) so a client can tell
    which authorization server answered.
    """
    @spec error_redirect(Plug.Conn.t(), String.t(), Errors.t(), Config.t()) :: Plug.Conn.t()
    def error_redirect(conn, redirect_uri, %Errors{} = error, %Config{} = config) do
      log_error(conn, error)

      location =
        redirect_uri
        |> Errors.redirect_url(error)
        |> append_query(%{"iss" => config.issuer})

      redirect(conn, location)
    end

    @doc "A 302 to `location`, with no body worth reading."
    @spec redirect(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
    def redirect(conn, location) do
      conn
      |> no_store()
      |> put_resp_header("location", location)
      |> send_resp(302, "")
    end

    @doc "Append query parameters to a URL, preserving whatever is already there."
    @spec append_query(String.t(), map()) :: String.t()
    def append_query(url, params) do
      uri = URI.parse(url)

      query =
        [uri.query, URI.encode_query(params)] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("&")

      URI.to_string(%{uri | query: query})
    end

    @doc "`cache-control: no-store` plus `pragma`, for HTTP/1.0 intermediaries."
    @spec no_store(Plug.Conn.t()) :: Plug.Conn.t()
    def no_store(conn) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")
    end

    @doc """
    Permissive CORS for the machine endpoints.

    `*` is correct here: these endpoints authenticate with a client secret, a PKCE
    verifier or a bearer — never with a cookie — so a browser attaching an origin
    gains nothing it did not already have. `allow-credentials` is deliberately
    absent, which is what keeps that true.
    """
    @spec cors(Plug.Conn.t()) :: Plug.Conn.t()
    def cors(conn) do
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-expose-headers", "WWW-Authenticate")
    end

    @doc "Answer a preflight with 204, or `nil` when this is not a preflight."
    @spec preflight(Plug.Conn.t(), String.t()) :: Plug.Conn.t() | nil
    def preflight(%{method: "OPTIONS"} = conn, methods) do
      requested = conn |> get_req_header("access-control-request-headers") |> List.first()

      conn
      |> cors()
      |> put_resp_header("access-control-allow-methods", methods)
      |> put_resp_header(
        "access-control-allow-headers",
        requested || "authorization, content-type"
      )
      |> put_resp_header("access-control-max-age", "600")
      |> send_resp(204, "")
    end

    def preflight(_conn, _methods), do: nil

    @doc """
    Run the host's rate-limit hook. Returns `{:error, conn}` with a `429` and a
    `retry-after` header when the caller is over its limit.

    The hook is host-owned on purpose — the library has no business deciding what
    "too many" means for your deployment, and both of our apps already run Hammer.
    """
    @spec rate_limit(Plug.Conn.t(), Config.t(), atom()) :: :ok | {:error, Plug.Conn.t()}
    def rate_limit(conn, %Config{} = config, endpoint) do
      case Server.rate_limit(config, endpoint, conn) do
        :ok ->
          :ok

        {:error, retry_after} ->
          response =
            conn
            |> put_resp_header("retry-after", to_string(retry_after))
            |> error_json(
              Errors.new(:temporarily_unavailable, reason: :rate_limited, status: 429)
            )

          {:error, response}
      end
    end

    @doc "405 with an `allow` header."
    @spec method_not_allowed(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
    def method_not_allowed(conn, allow) do
      conn
      |> put_resp_header("allow", allow)
      |> json(405, Errors.to_map(Errors.new(:invalid_request, reason: :bad_method)))
    end

    defp maybe_challenge(conn, %Errors{code: :invalid_client}) do
      put_resp_header(
        conn,
        "www-authenticate",
        Noizu.MCP.Auth.WWWAuthenticate.bearer_challenge(error: "invalid_client")
      )
    end

    defp maybe_challenge(conn, _error), do: conn

    # The private reason goes to the log; the response carries only the code.
    # That split is what keeps `error_description` from reflecting input while
    # still leaving something to debug with.
    defp log_error(conn, %Errors{} = error) do
      if error.reason || error.code == :server_error do
        Logger.info(
          "Auth.Server #{conn.method} #{conn.request_path}: #{error.code} (#{inspect(error.reason)})"
        )
      end

      :ok
    end

    defp parse_body(conn) do
      content_type = conn |> get_req_header("content-type") |> List.first() || ""

      case read_body(conn, length: 1_000_000) do
        {:ok, raw, conn} ->
          {conn, decode_body(raw, content_type)}

        {:more, _partial, conn} ->
          # An OAuth request that does not fit in 1 MB is not an OAuth request.
          {conn, %{}}

        {:error, _reason} ->
          {conn, %{}}
      end
    end

    defp decode_body("", _content_type), do: %{}

    defp decode_body(raw, content_type) do
      cond do
        String.contains?(content_type, "json") ->
          case Jason.decode(raw) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        String.contains?(content_type, "form-urlencoded") ->
          URI.decode_query(raw)

        true ->
          # RFC 6749 mandates form encoding on the token endpoint; be lenient
          # about a missing content-type, strict about the shape.
          case Jason.decode(raw) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> URI.decode_query(raw)
          end
      end
    end
  end
end
