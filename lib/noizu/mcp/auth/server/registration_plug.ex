if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.RegistrationPlug do
    @moduledoc """
    RFC 7591 dynamic client registration — `POST /oauth/register`.

    This is the endpoint Claude Desktop and Claude Code use when you paste an MCP
    URL: they register themselves, then run the authorization-code flow. Authentik
    has never supported it, which is why this facade exists.

    Disabled unless `dcr: [enabled: true]`, and when disabled the metadata document
    omits `registration_endpoint` so a client never tries.

    ## What keeps an open registration endpoint safe

      * Every `redirect_uri` is validated (https, or loopback http; no fragment, no
        userinfo, no wildcard) and, with `allowed_redirect_hosts`, matched on a
        **label boundary** — so `https://evil-claude.ai/cb` cannot register itself
        as a claude.ai callback
      * Consent is mandatory for a registered client before any code is issued, so
        a registration on its own grants nothing
      * The rate-limit hook fires here (`:register`), because an unlimited
        registration endpoint is a free row-writer
      * `initial_access_token:` closes it entirely to callers without a token
      * `cache-control: no-store` — the response contains a client secret

    RFC 7592 client *management* (a `registration_access_token` and the CRUD that
    goes with it) is deliberately out of scope: nothing in the MCP client
    ecosystem uses it, and it is more credential to leak.
    """

    @behaviour Plug

    alias Noizu.MCP.Auth.Server
    alias Noizu.MCP.Auth.Server.Client
    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.Errors
    alias Noizu.MCP.Auth.Server.PlugSupport

    @impl Plug
    def init(opts), do: PlugSupport.config(opts)

    @impl Plug
    def call(conn, %Config{} = config) do
      case PlugSupport.preflight(conn, "POST, OPTIONS") do
        nil -> serve(conn, config)
        answered -> answered
      end
    end

    defp serve(%{method: "POST"} = conn, config) do
      conn = PlugSupport.cors(conn)

      with :ok <- enabled(config),
           :ok <- PlugSupport.rate_limit(conn, config, :register),
           {:ok, conn, params} <- PlugSupport.read_params(conn),
           :ok <- initial_access_token(conn, config),
           {:ok, client, secret} <- Client.from_registration(params, config),
           {:ok, stored} <- put_client(client, config) do
        PlugSupport.json(conn, 201, Client.to_registration_response(stored, secret))
      else
        {:error, %Errors{} = error} -> PlugSupport.error_json(conn, error)
        {:error, %Plug.Conn{} = rate_limited} -> rate_limited
      end
    end

    defp serve(conn, _config), do: PlugSupport.method_not_allowed(conn, "POST, OPTIONS")

    defp enabled(config) do
      if Server.dcr_enabled?(config) do
        :ok
      else
        {:error, Errors.new(:invalid_request, reason: :dcr_disabled, status: 404)}
      end
    end

    # An operator can gate registration behind a token, which turns the endpoint
    # from open to invitation-only without changing anything else.
    defp initial_access_token(conn, %Config{dcr: dcr}) do
      case Keyword.get(dcr, :initial_access_token) do
        nil ->
          :ok

        check ->
          presented =
            case conn |> Plug.Conn.get_req_header("authorization") |> List.first() do
              "Bearer " <> token -> token
              "bearer " <> token -> token
              _ -> nil
            end

          if valid_initial_token?(check, presented) do
            :ok
          else
            {:error, Errors.new(:invalid_client, reason: :bad_initial_access_token)}
          end
      end
    end

    defp valid_initial_token?(_check, nil), do: false

    defp valid_initial_token?(check, presented) do
      case check do
        {module, fun} ->
          apply(module, fun, [presented]) == true

        fun when is_function(fun, 1) ->
          fun.(presented) == true

        expected when is_binary(expected) ->
          Noizu.MCP.Auth.Server.Secret.equal?(expected, presented)
      end
    end

    defp put_client(client, config) do
      {adapter, store_opts} = Config.store(config)

      case adapter.put_client(client, store_opts) do
        {:ok, stored} -> {:ok, stored}
        {:error, reason} -> {:error, Errors.new(:server_error, reason: reason)}
      end
    end
  end
end
