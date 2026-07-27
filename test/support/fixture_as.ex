defmodule Noizu.MCP.Fixtures.AS do
  @moduledoc false
  # Runtime configuration for the authorization-server E2E fixture.
  #
  # The issuer is not known until Bandit binds a port, and `forward`'s options are
  # evaluated at compile time — the exact footgun the plan warns hosts about. So
  # the fixture router builds its config per request from here instead, which is
  # also what a host doing this correctly looks like (`runtime.exs` + a function).

  alias Noizu.MCP.Auth.Server.Store

  @key {__MODULE__, :state}

  def setup(issuer, store_name) do
    :persistent_term.put(@key, %{
      issuer: issuer,
      store_name: store_name,
      # nil means "the ETS store named above". A test that wants the whole flow
      # driven by a different adapter — `Store.Ecto` against real Postgres —
      # overrides this with `put(:store, {Store.Ecto, repo: ..., subject_type: ...})`.
      store: nil,
      subject: "user-1",
      cimd_document: nil,
      upstream_log: nil
    })
  end

  def state, do: :persistent_term.get(@key, %{})

  def put(key, value), do: :persistent_term.put(@key, Map.put(state(), key, value))

  def issuer, do: state().issuer

  def resource(nil), do: issuer() <> "/mcp"
  def resource(domain), do: issuer() <> "/mcp/" <> domain

  @doc "The AS config, rebuilt per call so a test can change it mid-flight."
  def config do
    state = state()

    Noizu.MCP.Auth.Server.config(
      issuer: state.issuer,
      store: state[:store] || {Store.ETS, name: state.store_name},
      signing: {:hs256, "e2e-hmac-secret-that-is-long-enough-32"},
      scopes_supported: ["mcp", "mcp:admin"],
      default_scope: ["mcp"],
      resources: [
        [resource: state.issuer <> "/mcp", name: "Fixture root"],
        [resource: state.issuer <> "/mcp/learning", name: "Fixture learning"]
      ],
      dcr: [
        enabled: true,
        allowed_redirect_hosts: ["claude.ai"],
        secret_opts: [iterations: 1_000]
      ],
      cimd:
        [enabled: true, ssrf: [resolver: &Noizu.MCP.Fixtures.OAuth.resolver/1]] ++
          case Application.get_env(:noizu_mcp, :test_cimd_fetcher) do
            nil -> []
            fetcher -> [fetcher: fetcher]
          end,
      upstream:
        {Noizu.MCP.Auth.Server.Upstream.HostSession,
         current_subject: {__MODULE__, :current_subject}, login_url: {__MODULE__, :login_url}},
      api_keys: [validator: {Noizu.MCP.Fixtures.OAuth, :validate_api_key}, prefix: "mcp_live_"],
      access_token_ttl: 900
    )
  end

  # ── the host's side of Upstream.HostSession ──────────────────────────────

  @doc """
  Stands in for the host's session lookup. Records the request's `authorization`
  header, so `no_passthrough_test.exs` can prove the AS never treats an inbound
  bearer as identity.
  """
  def current_subject(conn) do
    log(:current_subject, Plug.Conn.get_req_header(conn, "authorization"))

    case state().subject do
      nil -> :none
      subject -> {:ok, subject}
    end
  end

  def login_url(_conn, return_to),
    do: "/fixture-login?return_to=" <> URI.encode_www_form(return_to)

  # ── an upstream request log, for the no-passthrough proof ────────────────

  def track_upstream(pid), do: put(:upstream_log, pid)

  def log(event, payload) do
    case state()[:upstream_log] do
      pid when is_pid(pid) -> send(pid, {:upstream, event, payload})
      _ -> :ok
    end
  end

  # ── CIMD ─────────────────────────────────────────────────────────────────

  def put_cimd_document(document), do: put(:cimd_document, document)

  @doc "A stub CIMD fetcher — the network never enters into it."
  def fetch_cimd(url, _opts) do
    log(:cimd_fetch, url)

    case state().cimd_document do
      nil -> {:error, :not_found}
      document -> {:ok, %{status: 200, body: document, headers: %{"etag" => ~s("v1")}}}
    end
  end
end

defmodule Noizu.MCP.Fixtures.ASRouter do
  @moduledoc false
  # One Bandit listener carrying the whole surface a host mounts: AS metadata,
  # protected-resource metadata for two mounts, the OAuth router, and two MCP
  # endpoints whose verifiers are audience-bound to their own mount.

  use Plug.Router

  alias Noizu.MCP.Auth.JWTVerifier
  alias Noizu.MCP.Auth.Server.ApiKeyTokenPlug
  alias Noizu.MCP.Auth.Server.MetadataPlug
  alias Noizu.MCP.Auth.Server.Router, as: OAuthRouter
  alias Noizu.MCP.Auth.Server.Tokens
  alias Noizu.MCP.Fixtures.AS
  alias Noizu.MCP.Transport.StreamableHTTP

  plug(:match)
  plug(:dispatch)

  get "/.well-known/oauth-authorization-server" do
    MetadataPlug.call(conn, MetadataPlug.init(AS.config()))
  end

  get "/.well-known/openid-configuration" do
    MetadataPlug.call(conn, MetadataPlug.init(AS.config()))
  end

  get "/.well-known/oauth-protected-resource/*rest" do
    prm(conn)
  end

  match "/api/mcp/token" do
    ApiKeyTokenPlug.call(conn, ApiKeyTokenPlug.init(AS.config()))
  end

  match "/oauth/*_rest" do
    OAuthRouter.call(conn, OAuthRouter.init(AS.config()))
  end

  match "/mcp/learning" do
    mcp(conn, "learning")
  end

  match "/mcp" do
    mcp(conn, nil)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp prm(conn) do
    opts =
      Noizu.MCP.Auth.ProtectedResourceMetadataPlug.init(
        authorization_servers: [AS.issuer()],
        scopes_supported: ["mcp"],
        bearer_methods_supported: ["header"],
        default_resource: "/mcp",
        resources: %{
          "/mcp" => [resource: AS.resource(nil)],
          "/mcp/learning" => [resource: AS.resource("learning")]
        }
      )

    # Strip the well-known prefix so the plug sees only the mount suffix, exactly
    # as a Phoenix `forward` would.
    suffix = Enum.drop(conn.path_info, 2)
    Noizu.MCP.Auth.ProtectedResourceMetadataPlug.call(%{conn | path_info: suffix}, opts)
  end

  defp mcp(conn, domain) do
    config = AS.config()
    resource = AS.resource(domain)

    opts =
      StreamableHTTP.Plug.init(
        server: Noizu.MCP.Fixtures.Server,
        origins: :mcp_clients,
        cors: true,
        auth: [
          verifier: {JWTVerifier, Tokens.verifier_opts(config, resource)},
          resource_metadata: :derive,
          scope: "mcp"
        ]
      )

    # What a Phoenix `forward` leaves behind: the mount path moves to
    # script_name, which is what `resource_metadata: :derive` reads.
    StreamableHTTP.Plug.call(%{conn | path_info: [], script_name: conn.path_info}, opts)
  end
end
