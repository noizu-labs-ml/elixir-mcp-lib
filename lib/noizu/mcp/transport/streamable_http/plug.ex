if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Transport.StreamableHTTP.Plug do
    @moduledoc """
    Streamable HTTP server transport (MCP 2025-11-25): a single MCP endpoint
    handling POST/GET/DELETE, mountable in Phoenix or any Plug stack:

        # Phoenix router
        forward "/mcp", Noizu.MCP.Transport.StreamableHTTP.Plug, server: MyApp.MCP

        # standalone with Bandit
        {Bandit, plug: {Noizu.MCP.Transport.StreamableHTTP.Plug, server: MyApp.MCP}, port: 4040}

    Behavior per spec: `initialize` POSTs create a session and return
    `Mcp-Session-Id`; requests answer as `application/json` when the handler
    produces only a response, upgrading to an SSE stream when progress,
    logging, or server-initiated requests flow first; GET opens the general
    SSE stream (with `Last-Event-ID` resumability backed by
    `Noizu.MCP.Server.EventStore`); DELETE terminates the session.

    ## Options

      * `:server` (required) — the `use Noizu.MCP.Server` module
      * `:origins` — `:localhost` (default; allows non-browser clients and
        localhost origins), `:mcp_clients` (localhost plus the known browser
        MCP hosts, see `mcp_client_origins/0`), `:any`, or an explicit
        allowlist of origins. Origin validation guards against DNS-rebinding
        attacks.
      * `:idle_timeout` — session idle expiry in ms (default 30 minutes)
      * `:request_timeout` — max time to wait for a handler response
        (default 300_000)
      * `:keepalive` — SSE keepalive comment interval in ms (default 25_000)
      * `:context` — `{module, function}` invoked as `fun.(conn)` returning a
        map merged into session assigns at initialize (how plug-level auth
        reaches handlers)
      * `:auth` — resource-server enforcement, see below
      * `:cors` — `false` (default) or `true`/keyword to answer browser
        preflights, see below

    ## Authorization (`:auth`)

      * `:verifier` (required) — `Noizu.MCP.Auth.TokenVerifier` module or
        `{module, opts}`
      * `:resource_metadata` — the RFC 9728 URL advertised in the 401
        challenge. A binary, `{module, function}` (called with the conn),
        `{module, function, args}`, a 1-arity fun, or `:derive` (built from the
        request and the forward's mount path).
      * `:scope` — scope advertised in the challenge, so a client that has
        never seen a token knows what to ask for

    ## CORS (`:cors`)

    A browser MCP client (claude.ai) cannot read the 401 challenge — and so
    cannot start OAuth — unless `WWW-Authenticate` is exposed, and cannot
    continue a session unless `Mcp-Session-Id` is. Enabling `:cors` answers
    `OPTIONS` with `204` and adds, to every response:

        access-control-allow-origin: <origin>
        access-control-expose-headers: WWW-Authenticate, Mcp-Session-Id, Mcp-Protocol-Version

    Only origins that pass `:origins` are answered, so CORS never widens the
    DNS-rebinding guard. Options: `allow_headers:`, `max_age:`.
    """

    @behaviour Plug
    import Plug.Conn
    require Logger

    alias Noizu.MCP.Protocol.Version
    alias Noizu.MCP.Server.EventStore
    alias Noizu.MCP.Server.Session
    alias Noizu.MCP.Transport.SSE
    alias Noizu.MCP.Transport.StreamableHTTP.Sink

    @exposed_headers "WWW-Authenticate, Mcp-Session-Id, Mcp-Protocol-Version"
    @default_allow_headers "authorization, content-type, accept, mcp-session-id, mcp-protocol-version, last-event-id"

    # Browser-context MCP hosts. Non-browser clients (Claude Desktop, Claude
    # Code, Codex) send no Origin at all and are unaffected by this list.
    @mcp_client_origins [
      "https://claude.ai",
      "https://www.claude.ai",
      "https://claude.com",
      "https://www.claude.com",
      "https://chatgpt.com",
      "https://inspector.modelcontextprotocol.io"
    ]

    @doc """
    The origins allowed by `origins: :mcp_clients` — the browser MCP hosts,
    which `:mcp_clients` allows in addition to localhost.

    Extend it rather than replacing it when a host needs one more origin:

        origins: ["https://mcp.internal" | Noizu.MCP.Transport.StreamableHTTP.Plug.mcp_client_origins()]
    """
    @spec mcp_client_origins() :: [String.t()]
    def mcp_client_origins, do: @mcp_client_origins

    @impl Plug
    # ⟦𓈟𓌖𓀽𓃤⟧ init :: auto-generated pointer for public function init
    def init(opts) do
      auth = Keyword.get(opts, :auth)
      warn_unauthenticated(opts, auth)

      %{
        server: Keyword.fetch!(opts, :server),
        origins: Keyword.get(opts, :origins, :localhost),
        idle_timeout: Keyword.get(opts, :idle_timeout, :timer.minutes(30)),
        request_timeout: Keyword.get(opts, :request_timeout, 300_000),
        init_timeout: Keyword.get(opts, :init_timeout, 30_000),
        keepalive: Keyword.get(opts, :keepalive, 25_000),
        sse_commit_after: Keyword.get(opts, :sse_commit_after, 200),
        context: Keyword.get(opts, :context),
        auth: auth,
        cors: normalize_cors(Keyword.get(opts, :cors, false))
      }
    end

    @impl Plug
    # ⟦𓃺𓁘𓐪𓊑⟧ call :: auto-generated pointer for public function call
    def call(conn, opts) do
      cond do
        not origin_allowed?(conn, opts.origins) ->
          send_resp(conn, 403, "Forbidden origin")

        conn.path_info != [] ->
          send_resp(conn, 404, "Not found")

        true ->
          conn = put_cors_headers(conn, opts.cors)

          # A preflight carries no Authorization header — answer it before auth.
          if opts.cors && conn.method == "OPTIONS" do
            preflight(conn, opts.cors)
          else
            case authenticate(conn, opts.auth) do
              {:ok, conn} -> route(conn, opts)
              {:halt, conn} -> conn
            end
          end
      end
    end

    defp route(conn, opts) do
      case conn.method do
        "POST" ->
          handle_post(conn, opts)

        "GET" ->
          handle_get(conn, opts)

        "DELETE" ->
          handle_delete(conn, opts)

        _ ->
          conn
          |> put_resp_header("allow", "GET, POST, DELETE")
          |> send_resp(405, "Method not allowed")
      end
    end

    # ── authorization (OAuth 2.1 resource server) ────────────────────────────

    defp authenticate(conn, nil), do: {:ok, conn}

    defp authenticate(conn, auth) do
      {verifier, verifier_opts} = normalize_verifier(Keyword.fetch!(auth, :verifier))

      case bearer_token(conn) do
        nil ->
          # No credential presented: per RFC 6750 §3.1 the challenge carries no
          # `error` — the client hasn't done anything wrong yet, it just needs
          # to be told where the authorization server is.
          {:halt, unauthorized(conn, auth, nil)}

        token ->
          conn_info = %{method: conn.method, peer: conn.remote_ip, headers: conn.req_headers}

          case verifier.verify(token, conn_info, verifier_opts) do
            {:ok, claims} ->
              {:ok, assign(conn, :mcp_auth_claims, claims)}

            {:error, :invalid_token} ->
              {:halt, unauthorized(conn, auth, "invalid_token")}

            {:error, :insufficient_scope, meta} ->
              # A `scope` in meta names what the caller is missing and wins over
              # the statically advertised scope.
              meta = Map.new(meta, fn {key, value} -> {to_string(key), to_string(value)} end)

              challenge =
                Noizu.MCP.Auth.WWWAuthenticate.bearer_challenge(
                  [
                    {"resource_metadata", resource_metadata_url(conn, auth)},
                    {"scope", meta["scope"] || Keyword.get(auth, :scope)},
                    {"error", "insufficient_scope"}
                  ] ++ Enum.reject(meta, fn {key, _} -> key == "scope" end)
                )

              conn
              |> put_resp_header("www-authenticate", challenge)
              |> send_resp(403, "Insufficient scope")
              |> then(&{:halt, &1})
          end
      end
    end

    defp normalize_verifier({module, opts}), do: {module, opts}
    defp normalize_verifier(module) when is_atom(module), do: {module, []}

    defp bearer_token(conn) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> token
        ["bearer " <> token | _] -> token
        _ -> nil
      end
    end

    defp unauthorized(conn, auth, error) do
      challenge =
        Noizu.MCP.Auth.WWWAuthenticate.bearer_challenge(
          resource_metadata: resource_metadata_url(conn, auth),
          scope: Keyword.get(auth, :scope),
          error: error
        )

      conn
      |> put_resp_header("www-authenticate", challenge)
      |> send_resp(401, "Unauthorized")
    end

    defp resource_metadata_url(conn, auth) do
      case Keyword.get(auth, :resource_metadata) do
        nil -> nil
        url when is_binary(url) -> url
        :derive -> derive_resource_metadata(conn)
        {module, fun} when is_atom(module) and is_atom(fun) -> apply(module, fun, [conn])
        {module, fun, args} when is_list(args) -> apply(module, fun, args)
        fun when is_function(fun, 1) -> fun.(conn)
      end
    end

    # RFC 9728 path insertion: the mount path of this forward becomes the
    # well-known suffix, so `https://host/mcp/learning` is described by
    # `https://host/.well-known/oauth-protected-resource/mcp/learning`.
    defp derive_resource_metadata(conn) do
      base = "#{conn.scheme}://#{authority(conn)}/.well-known/oauth-protected-resource"

      case Enum.join(conn.script_name, "/") do
        "" -> base
        suffix -> base <> "/" <> suffix
      end
    end

    defp authority(%{host: host, port: port, scheme: scheme}) do
      cond do
        scheme == :https and port == 443 -> host
        scheme == :http and port == 80 -> host
        true -> "#{host}:#{port}"
      end
    end

    # ── CORS ─────────────────────────────────────────────────────────────────

    defp normalize_cors(false), do: nil
    defp normalize_cors(nil), do: nil
    defp normalize_cors(true), do: %{allow_headers: @default_allow_headers, max_age: 600}

    defp normalize_cors(opts) when is_list(opts) or is_map(opts) do
      opts = Enum.into(opts, [])

      %{
        allow_headers: Keyword.get(opts, :allow_headers, @default_allow_headers),
        max_age: Keyword.get(opts, :max_age, 600)
      }
    end

    defp put_cors_headers(conn, nil), do: conn

    defp put_cors_headers(conn, _cors) do
      # Reached only after `origin_allowed?/2`, so echoing the origin cannot
      # widen the allowlist. No `allow-credentials`: MCP authenticates with a
      # bearer header, never a cookie.
      case get_req_header(conn, "origin") do
        [origin | _] ->
          conn
          |> put_resp_header("access-control-allow-origin", origin)
          |> put_resp_header("access-control-expose-headers", @exposed_headers)
          |> put_resp_header("vary", "origin")

        [] ->
          conn
      end
    end

    defp preflight(conn, cors) do
      requested =
        conn |> get_req_header("access-control-request-headers") |> List.first()

      conn
      |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
      |> put_resp_header("access-control-allow-headers", requested || cors.allow_headers)
      |> put_resp_header("access-control-max-age", to_string(cors.max_age))
      |> send_resp(204, "")
    end

    # ── init-time diagnostics ────────────────────────────────────────────────

    defp warn_unauthenticated(opts, nil) do
      if prod_env?() do
        Logger.warning("""
        Noizu.MCP.Transport.StreamableHTTP.Plug mounted without `auth:` for \
        #{inspect(Keyword.get(opts, :server))}. Every tool on this mount is \
        reachable unauthenticated. Pass `auth: [verifier: ..., resource_metadata: ...]` \
        or set `origins:` so only trusted callers can reach it.\
        """)
      end
    end

    defp warn_unauthenticated(_opts, _auth), do: :ok

    defp prod_env? do
      case Application.get_env(:noizu_mcp, :env) do
        nil ->
          # `init/1` normally runs at compile time (Plug's `:compile` init
          # mode), where Mix is available; in a release it is not, and a
          # release is prod.
          not (Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0)) or Mix.env() == :prod

        env ->
          env == :prod
      end
    end

    # ── POST ─────────────────────────────────────────────────────────────────

    defp handle_post(conn, opts) do
      with {:ok, conn, body} <- decoded_body(conn),
           :ok <- check_protocol_version(conn) do
        case classify(body) do
          {:initialize, id} ->
            handle_initialize(conn, opts, body, id)

          {:request, id} ->
            with {:ok, session} <- find_session(conn, opts.server) do
              handle_request(conn, opts, body, id, session)
            else
              {:error, conn_response} -> conn_response
            end

          :one_way ->
            with {:ok, session} <- find_session(conn, opts.server) do
              Session.deliver(session, Jason.encode!(body))
              send_resp(conn, 202, "")
            else
              {:error, conn_response} -> conn_response
            end

          :invalid ->
            send_resp(conn, 400, "Not a JSON-RPC message")
        end
      else
        {:error, :bad_body} ->
          send_resp(conn, 400, "Invalid JSON body")

        {:error, :bad_version} ->
          send_resp(conn, 400, "Unsupported MCP-Protocol-Version")
      end
    end

    defp classify(%{"method" => "initialize", "id" => id}) when is_integer(id) or is_binary(id),
      do: {:initialize, id}

    defp classify(%{"method" => _, "id" => id}) when is_integer(id) or is_binary(id),
      do: {:request, id}

    defp classify(%{"method" => _}), do: :one_way
    defp classify(%{"id" => _, "result" => _}), do: :one_way
    defp classify(%{"id" => _, "error" => _}), do: :one_way
    defp classify(_), do: :invalid

    defp handle_initialize(conn, opts, body, id) do
      server = opts.server
      session_id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      assigns =
        case opts.context do
          {module, fun} -> apply(module, fun, [conn])
          fun when is_function(fun, 1) -> fun.(conn)
          nil -> %{}
        end
        |> then(fn assigns ->
          case conn.assigns[:mcp_auth_claims] do
            nil -> assigns
            claims -> Map.put(assigns, :auth_claims, claims)
          end
        end)

      {:ok, session} =
        Noizu.MCP.Server.Supervisor.start_session(server,
          sink: {Sink, {server, session_id}},
          transport: :http,
          session_id: session_id,
          idle_timeout: opts.idle_timeout,
          assigns: assigns
        )

      registry = Module.concat(server, Registry)
      Registry.register(registry, {:http_stream, session_id, id}, nil)
      Session.deliver(session, Jason.encode!(body))

      receive do
        {:mcp_http, binary} ->
          Registry.unregister(registry, {:http_stream, session_id, id})

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("mcp-session-id", session_id)
          |> send_resp(200, binary)
      after
        opts.init_timeout ->
          send_resp(conn, 500, "Initialize timed out")
      end
    end

    defp handle_request(conn, opts, body, id, session) do
      server = opts.server
      session_id = session_id!(conn)
      registry = Module.concat(server, Registry)

      monitor = Process.monitor(session)
      Registry.register(registry, {:http_stream, session_id, id}, nil)
      Session.deliver(session, Jason.encode!(body))

      deadline = System.monotonic_time(:millisecond) + opts.request_timeout
      stream_request(conn, opts, id, monitor, deadline, false)
    end

    defp stream_request(conn, opts, id, monitor, deadline, sse?) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:mcp_http, binary} ->
          final? = final_response?(binary, id)

          cond do
            final? and not sse? ->
              Process.demonitor(monitor, [:flush])

              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, binary)

            final? and sse? ->
              Process.demonitor(monitor, [:flush])
              {:ok, conn} = chunk(conn, SSE.encode(binary))
              conn

            not final? and sse? ->
              {:ok, conn} = chunk(conn, SSE.encode(binary))
              stream_request(conn, opts, id, monitor, deadline, true)

            true ->
              # First non-final message — upgrade to SSE.
              conn = open_sse(conn)
              {:ok, conn} = chunk(conn, SSE.encode(binary))
              stream_request(conn, opts, id, monitor, deadline, true)
          end

        {:DOWN, ^monitor, :process, _pid, _reason} ->
          if sse?, do: conn, else: send_resp(conn, 500, "Session terminated")
      after
        min(remaining, if(sse?, do: opts.keepalive, else: opts.sse_commit_after)) ->
          cond do
            remaining <= 0 and sse? ->
              conn

            remaining <= 0 ->
              Process.demonitor(monitor, [:flush])
              send_resp(conn, 504, "Request timed out")

            sse? ->
              {:ok, conn} = chunk(conn, ": keepalive\n\n")
              stream_request(conn, opts, id, monitor, deadline, true)

            true ->
              # No response within the grace window — commit to SSE so the
              # client sees response status promptly (it may be serializing
              # POST initiation on it) and gets keepalives during a long call.
              stream_request(open_sse(conn), opts, id, monitor, deadline, true)
          end
      end
    end

    defp open_sse(conn) do
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)
    end

    defp final_response?(binary, id) do
      case Jason.decode(binary) do
        {:ok, %{"id" => ^id} = decoded} ->
          Map.has_key?(decoded, "result") or Map.has_key?(decoded, "error")

        _ ->
          false
      end
    end

    # ── GET (general SSE stream) ─────────────────────────────────────────────

    defp handle_get(conn, opts) do
      accepts_sse? =
        conn
        |> get_req_header("accept")
        |> Enum.any?(&(&1 =~ "text/event-stream" or &1 =~ "*/*"))

      with true <- accepts_sse? || {:error, :not_acceptable},
           {:ok, session} <- find_session(conn, opts.server) do
        server = opts.server
        session_id = session_id!(conn)
        registry = Module.concat(server, Registry)

        case Registry.register(registry, {:http_get, session_id}, nil) do
          {:ok, _} ->
            monitor = Process.monitor(session)

            conn =
              conn
              |> put_resp_content_type("text/event-stream")
              |> put_resp_header("cache-control", "no-cache")
              |> send_chunked(200)

            last_event_id = conn |> get_req_header("last-event-id") |> List.first()

            conn =
              Enum.reduce_while(
                EventStore.replay_after(server, session_id, last_event_id),
                conn,
                fn {event_id, binary}, conn ->
                  case chunk(conn, SSE.encode(binary, id: event_id)) do
                    {:ok, conn} -> {:cont, conn}
                    {:error, _} -> {:halt, conn}
                  end
                end
              )

            stream_get(conn, opts, monitor)

          {:error, {:already_registered, _}} ->
            send_resp(conn, 409, "A stream is already open for this session")
        end
      else
        {:error, :not_acceptable} ->
          send_resp(conn, 406, "GET requires Accept: text/event-stream")

        {:error, conn_response} ->
          conn_response
      end
    end

    defp stream_get(conn, opts, monitor) do
      receive do
        {:mcp_http_event, event_id, binary} ->
          case chunk(conn, SSE.encode(binary, id: event_id)) do
            {:ok, conn} -> stream_get(conn, opts, monitor)
            {:error, _closed} -> conn
          end

        :mcp_http_close ->
          conn

        {:DOWN, ^monitor, :process, _pid, _reason} ->
          conn
      after
        opts.keepalive ->
          case chunk(conn, ": keepalive\n\n") do
            {:ok, conn} -> stream_get(conn, opts, monitor)
            {:error, _closed} -> conn
          end
      end
    end

    # ── DELETE ───────────────────────────────────────────────────────────────

    defp handle_delete(conn, opts) do
      with {:ok, session} <- find_session(conn, opts.server) do
        GenServer.stop(session, :normal)
        send_resp(conn, 200, "")
      else
        {:error, conn_response} -> conn_response
      end
    end

    # ── helpers ──────────────────────────────────────────────────────────────

    defp find_session(conn, server) do
      case get_req_header(conn, "mcp-session-id") do
        [session_id | _] ->
          case Registry.lookup(Module.concat(server, Registry), {:session, session_id}) do
            [{pid, _} | _] -> {:ok, pid}
            [] -> {:error, send_resp(conn, 404, "Unknown or expired session")}
          end

        [] ->
          {:error, send_resp(conn, 400, "Missing Mcp-Session-Id header")}
      end
    end

    defp session_id!(conn), do: conn |> get_req_header("mcp-session-id") |> List.first()

    defp decoded_body(conn) do
      case conn.body_params do
        %Plug.Conn.Unfetched{} ->
          case read_body(conn) do
            {:ok, raw, conn} ->
              case Jason.decode(raw) do
                {:ok, body} -> {:ok, conn, body}
                {:error, _} -> {:error, :bad_body}
              end

            _ ->
              {:error, :bad_body}
          end

        %{} = parsed ->
          {:ok, conn, parsed}
      end
    end

    defp check_protocol_version(conn) do
      case get_req_header(conn, "mcp-protocol-version") do
        [] -> :ok
        [version | _] -> if Version.supported?(version), do: :ok, else: {:error, :bad_version}
      end
    end

    defp origin_allowed?(conn, policy) do
      case get_req_header(conn, "origin") do
        [] ->
          true

        [origin | _] ->
          case policy do
            :any ->
              true

            :localhost ->
              loopback_origin?(origin)

            :mcp_clients ->
              loopback_origin?(origin) or origin in @mcp_client_origins

            allowed when is_list(allowed) ->
              origin in allowed
          end
      end
    end

    defp loopback_origin?(origin) do
      case URI.parse(origin) do
        %URI{host: host} when host in ["localhost", "127.0.0.1", "[::1]", "::1"] -> true
        _ -> false
      end
    end
  end
end
