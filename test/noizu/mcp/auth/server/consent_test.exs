defmodule Noizu.MCP.Auth.Server.ConsentTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server
  alias Noizu.MCP.Auth.Server.Client
  alias Noizu.MCP.Auth.Server.Consent
  alias Noizu.MCP.Auth.Server.Store

  setup do
    name = Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")
    start_supervised!({Store.ETS, name: name})

    config =
      Server.config(
        issuer: "https://app.example.com",
        store: {Store.ETS, name: name},
        signing: {:hs256, "a-secret-long-enough-for-hs256-use"},
        upstream: {Noizu.MCP.Auth.Server.Upstream.HostSession, []},
        scopes_supported: ["mcp", "mcp:admin"]
      )

    client = %Client{client_id: "mcp_abc", client_id_kind: :registered, client_name: "Agent"}
    {:ok, _} = Store.ETS.put_client(client, name: name)

    %{config: config, client: client, store: [name: name]}
  end

  describe "required?/4" do
    test "a first-time registered client always prompts", %{config: config, client: client} do
      assert {:prompt, :no_consent} = Consent.required?(client, "user-1", ["mcp"], config)
    end

    test "a granted scope skips", %{config: config, client: client} do
      :ok = Consent.record(client, "user-1", ["mcp"], nil, config)
      assert :skip = Consent.required?(client, "user-1", ["mcp"], config)
    end

    test "a broadened scope re-prompts — the spec's confused-deputy requirement", %{
      config: config,
      client: client
    } do
      :ok = Consent.record(client, "user-1", ["mcp"], nil, config)

      assert {:prompt, :scope_broadened} =
               Consent.required?(client, "user-1", ["mcp", "mcp:admin"], config)
    end

    test "a narrowed scope still skips", %{config: config, client: client} do
      :ok = Consent.record(client, "user-1", ["mcp", "mcp:admin"], nil, config)
      assert :skip = Consent.required?(client, "user-1", ["mcp"], config)
    end

    test "consent is per subject", %{config: config, client: client} do
      :ok = Consent.record(client, "user-1", ["mcp"], nil, config)
      assert {:prompt, :no_consent} = Consent.required?(client, "user-2", ["mcp"], config)
    end

    test "consent: [enabled: false] does not exempt a self-registered client", %{
      config: config,
      client: client
    } do
      config = %{config | consent: [enabled: false]}
      assert {:prompt, :no_consent} = Consent.required?(client, "user-1", ["mcp"], config)

      # It does exempt a preconfigured one, which an operator created deliberately.
      preconfigured = %{client | client_id_kind: :preconfigured}
      assert :skip = Consent.required?(preconfigured, "user-1", ["mcp"], config)
    end

    test "a preconfigured client still prompts by default", %{config: config, client: client} do
      preconfigured = %{client | client_id_kind: :preconfigured}
      assert {:prompt, :no_consent} = Consent.required?(preconfigured, "user-1", ["mcp"], config)
    end
  end

  describe "record/5" do
    test "merges with what was granted before", %{config: config, client: client} do
      :ok = Consent.record(client, "user-1", ["mcp"], nil, config)
      :ok = Consent.record(client, "user-1", ["mcp:admin"], nil, config)

      assert {:ok, consent} = Consent.granted(client, "user-1", config)
      assert Enum.sort(consent.scope) == ["mcp", "mcp:admin"]
    end

    test "revoke/3 removes it", %{config: config, client: client} do
      :ok = Consent.record(client, "user-1", ["mcp"], nil, config)
      :ok = Consent.revoke("user-1", client.client_id, config)

      assert {:error, :not_found} = Consent.granted(client, "user-1", config)
    end

    test "an expiring consent stops counting", %{config: config, client: client, store: store} do
      config = %{config | consent: [ttl: -60]}
      :ok = Consent.record(client, "user-1", ["mcp"], nil, config)

      # Written, but already expired — so the store hides it and the flow re-prompts.
      assert {:error, :not_found} = Store.ETS.get_consent("user-1", client.client_id, store)
      assert {:prompt, :no_consent} = Consent.required?(client, "user-1", ["mcp"], config)
    end
  end

  describe "CSRF" do
    test "a token matches only itself" do
      token = Consent.csrf_token()
      payload = %{"csrf_token" => token}

      assert Consent.valid_csrf?(payload, token)
      refute Consent.valid_csrf?(payload, Consent.csrf_token())
      refute Consent.valid_csrf?(payload, String.slice(token, 0..-2//1))
    end

    test "a flow with no stored token fails closed" do
      # An absent token must never read as "no CSRF protection needed".
      refute Consent.valid_csrf?(%{}, "anything")
      refute Consent.valid_csrf?(%{"csrf_token" => nil}, "anything")
      refute Consent.valid_csrf?(%{"csrf_token" => "abc"}, nil)
      refute Consent.valid_csrf?(%{"csrf_token" => "abc"}, 123)
    end

    test "tokens are unique per flow" do
      tokens = for _ <- 1..50, do: Consent.csrf_token()
      assert length(Enum.uniq(tokens)) == 50
    end
  end

  describe "render_html/1" do
    defp assigns(overrides \\ %{}) do
      Map.merge(
        %{
          client: %Client{
            client_id: "mcp_abc",
            client_id_kind: :registered,
            client_name: "Agent"
          },
          subject: "user-1",
          scope: ["mcp"],
          resource: "https://app.example.com/mcp",
          csrf_token: "csrf-token-value",
          login_state: "login-state-value",
          action: "https://app.example.com/oauth/consent"
        },
        overrides
      )
    end

    test "renders the client, the scopes and the form" do
      html = Consent.render_html(assigns())

      assert html =~ "Agent wants access to your account"
      assert html =~ "<code>mcp</code>"
      assert html =~ ~s(name="csrf_token" value="csrf-token-value")
      assert html =~ ~s(name="login_state" value="login-state-value")
      assert html =~ ~s(action="https://app.example.com/oauth/consent")
      assert html =~ "https://app.example.com/mcp"
    end

    test "warns that a registered client registered itself" do
      assert Consent.render_html(assigns()) =~ "registered itself"
    end

    test "shows a CIMD client's URL, which is the only thing identifying it" do
      html =
        Consent.render_html(
          assigns(%{
            client: %Client{
              client_id: "https://claude.ai/client",
              client_id_kind: :cimd,
              client_name: "Claude"
            }
          })
        )

      assert html =~ "https://claude.ai/client"
      assert html =~ "recognize that address"
    end

    test "escapes an attacker-chosen client name — it is stored XSS otherwise" do
      html =
        Consent.render_html(
          assigns(%{
            client: %Client{
              client_id: "mcp_abc",
              client_id_kind: :registered,
              client_name: ~S{<script>alert('xss')</script>}
            }
          })
        )

      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;"
      assert html =~ "&#39;"
    end

    test "escapes scope strings and the resource too" do
      html =
        Consent.render_html(
          assigns(%{
            scope: [~S{mcp"><img src=x onerror=alert(1)>}],
            resource: ~S{https://x/"><script>}
          })
        )

      refute html =~ "<img src=x"
      refute html =~ "\"><script>"
      assert html =~ "&quot;"
    end

    test "falls back to the client_id when there is no name" do
      html = Consent.render_html(assigns(%{client: %Client{client_id: "mcp_abc"}}))
      assert html =~ "mcp_abc wants access"
    end

    test "omits the resource line when there is no resource" do
      refute Consent.render_html(assigns(%{resource: nil})) =~ "Access is limited to"
    end
  end
end
