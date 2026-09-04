defmodule Noizu.MCP.Toolset.PersistedLayersTest do
  @moduledoc """
  The context-pass persisted-layer matrix (PRD-4 §4.5 / AC-4.2 .. AC-4.5):
  grant rename/reveal per principal, the weight sandwich (static 100 <
  grants 200 < ACL 300), negotiation satisfaction/unsatisfaction with the
  honest `:forbidden` resolve path, immutability, D5 outage degradation
  (loud) vs the Disabled policy (silent), effective-scope union with globs,
  and the AP-10 canary (grants are NOT a second ACL).
  """
  use ExUnit.Case, async: false

  import Noizu.MCP.Test

  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.Error
  alias Noizu.MCP.Fixtures.Persistence
  alias Noizu.MCP.JsonRpc
  alias Noizu.MCP.JsonRpc.Request
  alias Noizu.MCP.Permission.Grant
  alias Noizu.MCP.Permission.Negotiation
  alias Noizu.MCP.Persistence.Memory
  alias Noizu.MCP.Server.Session
  alias Noizu.MCP.Toolset.{Custom, Override}

  @await timeout: 2_000

  setup do
    Memory.reset()
    :ok
  end

  setup context do
    if context[:telemetry] do
      # The handler runs in the attaching (test) process — events land in the
      # test's mailbox for assert_receive.
      :ok =
        :telemetry.attach(
          "persisted-layers-test",
          [:noizu_mcp, :persistence, :error],
          &__MODULE__.handle_event/4,
          nil
        )

      on_exit(fn -> :telemetry.detach("persisted-layers-test") end)
    end

    :ok
  end

  # telemetry sink: events land in the test process mailbox.
  def handle_event([:noizu_mcp, :persistence, :error], _measurements, metadata, nil) do
    send(self(), {:persistence_error_telemetry, metadata})
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp principal(subject, scopes \\ []) do
    %Principal{
      subject: subject,
      authenticator: :claims,
      granted_scopes: MapSet.new(scopes)
    }
  end

  defp ctx(principal \\ nil, server \\ Persistence.GrantServer) do
    base = %{server: server}
    if principal, do: Map.put(base, :auth, principal), else: base
  end

  defp put_grant(overrides) do
    grant =
      struct(
        %Grant{
          id: "g-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
          toolset_slug: "grant-unit",
          authenticator: "claims",
          subject: "user-1",
          effect: :allow
        },
        overrides
      )

    :ok = Memory.put("toolset_grants", grant.id, grant, [])
    grant
  end

  defp put_negotiation(toolset_slug, overrides) do
    negotiation =
      struct(
        %Negotiation{
          id: "n-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
          toolset_slug: toolset_slug,
          authenticator: "claims",
          tool: "get_weather",
          required_scopes: ["pm:write"]
        },
        overrides
      )

    :ok = Memory.put("toolset_negotiations", negotiation.id, negotiation, [])
    negotiation
  end

  defp unit_toolset(slug, overrides \\ []) do
    struct(
      %Custom{
        slug: slug,
        base: Persistence.GrantServer,
        include: ["echo", "get_weather", "secret_echo"]
      },
      overrides
    )
  end

  defp listed_names(toolset, ctx, opts \\ []) do
    {:ok, entries, _version} = Noizu.MCP.Toolset.catalog(toolset, ctx, opts)

    entries
    |> Enum.filter(& &1.visible)
    |> Enum.map(& &1.definition.name)
  end

  # ── AC-4.2: grants adjust/extend per principal ───────────────────────────

  describe "grant layers (AC-4.2)" do
    test "an :allow grant with reveal+rename ops renames the tool for THAT principal only" do
      put_grant(
        tool_overrides: %{
          "secret_echo" => [
            %Override{op: :set_visible, value: true},
            %Override{op: :set_name, value: "echo_pro"}
          ]
        }
      )

      toolset = unit_toolset("grant-unit")
      granted = listed_names(toolset, ctx(principal("user-1")))
      assert "echo_pro" in granted
      refute "secret_echo" in granted
      # The base surface is intact for the granted caller too.
      assert "echo" in granted
      assert "get_weather" in granted

      # The second principal — no grant — sees the base surface.
      other = listed_names(toolset, ctx(principal("user-2")))
      refute "echo_pro" in other
      assert "echo" in other
      assert "get_weather" in other

      # Anonymous — no grant — same.
      refute "echo_pro" in listed_names(toolset, ctx())
    end

    test "grants never hide: a grant for one tool leaves the rest of the surface untouched" do
      put_grant(
        tool_overrides: %{"echo" => [%Override{op: :set_description, value: "grant-describe"}]}
      )

      toolset = unit_toolset("grant-unit")
      names = listed_names(toolset, ctx(principal("user-1")))
      assert MapSet.new(names) == MapSet.new(["echo", "get_weather"])

      {:ok, entries, _} = Noizu.MCP.Toolset.catalog(toolset, ctx(principal("user-1")), [])
      echo = Enum.find(entries, &(&1.definition.name == "echo"))
      assert echo.definition.description == "grant-describe"
    end
  end

  # ── AP-10: grants are NOT a second ACL ───────────────────────────────────

  describe "AP-10 canary (grants are not ACL)" do
    test "no grants + no ACL ⇒ base surface fully visible (absence is not denial)" do
      names = listed_names(unit_toolset("grant-unit"), ctx(principal("nobody")))
      assert MapSet.new(["echo", "get_weather"]) == MapSet.new(names -- ["secret_echo"])
      assert "echo" in names
      assert "get_weather" in names
    end

    test "paired: an ACL provider with a deny verdict hides, while grant absence never does" do
      # Same surface, ACL configured with DenyAll: everything invisible.
      toolset = unit_toolset("grant-unit")

      {:ok, entries, _} =
        Noizu.MCP.Toolset.catalog(toolset, ctx(principal("user-1")),
          acl: Noizu.MCP.ACL.Providers.DenyAll
        )

      assert Enum.all?(entries, &(&1.visible == false and &1.callable == false))
    end
  end

  # ── AC-4.4: the weight sandwich ──────────────────────────────────────────

  describe "weight sandwich (AC-4.4)" do
    test "a :deny grant beats static visibility (200 > 100)" do
      put_grant(
        effect: :deny,
        tool_overrides: %{"echo" => [%Override{op: :set_visible, value: true}]}
      )

      toolset =
        unit_toolset("grant-unit",
          tools: %{"echo" => [%Override{op: :set_visible, value: true}]}
        )

      {:ok, entries, _} = Noizu.MCP.Toolset.catalog(toolset, ctx(principal("user-1")), [])
      echo = Enum.find(entries, &(&1.definition.name == "echo"))

      assert echo.visible == false
      assert echo.callable == false
    end

    test "an ACL deny beats a :deny grant (300 > 200) with the denial reason preserved" do
      put_grant(effect: :deny, tool_overrides: %{"echo" => []})

      toolset = unit_toolset("grant-unit")

      {:ok, entries, _} =
        Noizu.MCP.Toolset.catalog(toolset, ctx(principal("user-1")),
          acl: Noizu.MCP.Fixtures.Custom.DenyEchoProvider
        )

      echo = Enum.find(entries, &(&1.definition.name == "echo"))
      assert echo.visible == false
      # PRD-2 preservation rule: the pre-ACL entry had no reason of its own
      # (the deny grant set visibility, not a reason), so the ACL attribution
      # stands.
      assert echo.reason == {:acl, Noizu.MCP.Fixtures.Custom.DenyEchoProvider}

      # Other tools: untouched by either mechanism.
      weather = Enum.find(entries, &(&1.definition.name == "get_weather"))
      assert weather.visible == true
    end
  end

  # ── AC-4.3: negotiation flows ────────────────────────────────────────────

  describe "negotiation layers (AC-4.3)" do
    test "unsatisfied negotiation: visible but callable false, forbidden on resolve with data" do
      put_negotiation("neg-unit", [])

      toolset = %Custom{
        slug: "neg-unit",
        base: Persistence.NegotiationServer,
        include: ["echo", "get_weather"]
      }

      {:ok, entries, _} = Noizu.MCP.Toolset.catalog(toolset, ctx(), [])
      weather = Enum.find(entries, &(&1.definition.name == "get_weather"))

      # Q2: consent-gated tools stay VISIBLE for discovery.
      assert weather.visible == true
      assert weather.callable == false
      assert {:negotiation_required, ["pm:write"]} = weather.reason

      # Anonymous resolve ⇒ the ONE honest :forbidden, with missing-scopes data.
      assert {:error, %Error{} = error} =
               Noizu.MCP.Toolset.resolve(toolset, "get_weather", ctx(), [])

      assert error.code == Error.forbidden("x").code

      assert %{tool: "get_weather", required_scopes: ["pm:write"], missing: ["pm:write"]} =
               error.data

      # The matched negotiation record rides the error (metadata passthrough,
      # PRD-5 §5) — even for anonymous callers (the gate is tool-wide).
      assert %{id: _, metadata: %{}} = error.data.negotiation

      # Other tools unaffected.
      assert {:ok, %Noizu.MCP.Toolset.Effective{}} =
               Noizu.MCP.Toolset.resolve(toolset, "echo", ctx(), [])
    end

    test "a principal holding the required scope is callable (effective-scope union)" do
      put_negotiation("neg-unit", [])

      toolset = %Custom{
        slug: "neg-unit",
        base: Persistence.NegotiationServer,
        include: ["echo", "get_weather"]
      }

      allowed = ctx(principal("user-1", ["pm:write"]))

      assert {:ok, %Noizu.MCP.Toolset.Effective{name: "get_weather"}} =
               Noizu.MCP.Toolset.resolve(toolset, "get_weather", allowed, [])
    end

    test "allow-grant scopes join the effective set (union + glob satisfaction)" do
      # The grant carries "pm:*" — a glob that covers pm:write. It targets the
      # SAME toolset the negotiation gates.
      put_grant(toolset_slug: "neg-unit", scopes: ["pm:*"])
      put_negotiation("neg-unit", [])

      toolset = %Custom{
        slug: "neg-unit",
        base: Persistence.NegotiationServer,
        include: ["echo", "get_weather"]
      }

      # Principal has NO scopes of their own — the union with the grant's
      # glob-covered scopes satisfies the negotiation.
      allowed = ctx(principal("user-1"))

      assert {:ok, %Noizu.MCP.Toolset.Effective{}} =
               Noizu.MCP.Toolset.resolve(toolset, "get_weather", allowed, [])
    end

    test "granted: true ⇒ callable and metadata_overrides fold onto _meta" do
      put_negotiation("neg-unit",
        granted: true,
        metadata_overrides: %{"elevation_uri" => "https://idp.example/consent"}
      )

      toolset = %Custom{
        slug: "neg-unit",
        base: Persistence.NegotiationServer,
        include: ["echo", "get_weather"]
      }

      {:ok, effective} = Noizu.MCP.Toolset.resolve(toolset, "get_weather", ctx(), [])
      assert effective.spec.definition.meta == %{"elevation_uri" => "https://idp.example/consent"}

      # The artifact rides the LISTING surface too (consent UX).
      {:ok, entries, _} = Noizu.MCP.Toolset.catalog(toolset, ctx(), [])
      weather = Enum.find(entries, &(&1.definition.name == "get_weather"))
      assert weather.definition.meta == %{"elevation_uri" => "https://idp.example/consent"}
    end

    test "most recent negotiation wins (inserted_at desc)" do
      now = DateTime.utc_now()

      put_negotiation("neg-unit",
        inserted_at: DateTime.add(now, -3_600, :second),
        required_scopes: ["pm:write", "deploy:*"]
      )

      put_negotiation("neg-unit", inserted_at: now)

      toolset = %Custom{
        slug: "neg-unit",
        base: Persistence.NegotiationServer,
        include: ["echo", "get_weather"]
      }

      # Only the newest record's requirement stands: a pm:write holder passes.
      allowed = ctx(principal("user-1", ["pm:write"]))

      assert {:ok, %Noizu.MCP.Toolset.Effective{}} =
               Noizu.MCP.Toolset.resolve(toolset, "get_weather", allowed, [])
    end
  end

  # ── AC-4.5: immutability ignores persisted layers, never ACL ─────────────

  describe "immutable toolsets (AC-4.5)" do
    test "grants and negotiations are ignored, ACL still checked" do
      put_grant(tool_overrides: %{"echo" => [%Override{op: :set_name, value: "echo_pro"}]})

      put_negotiation("grant-unit", tool: "echo", required_scopes: ["deploy:*"])

      immutable =
        unit_toolset("grant-unit", immutable: true)

      names = listed_names(immutable, ctx(principal("user-1")))
      # No rename, no gate — the static surface stands.
      refute "echo_pro" in names
      assert "echo" in names

      # ...but ACL still governs (immutability never defeats authorization).
      {:ok, entries, _} =
        Noizu.MCP.Toolset.catalog(immutable, ctx(principal("user-1")),
          acl: Noizu.MCP.Fixtures.Custom.DenyEchoProvider
        )

      echo = Enum.find(entries, &(&1.definition.name == "echo"))
      assert echo.visible == false
    end
  end

  # ── FR-4.10: outage degradation ──────────────────────────────────────────

  describe "D5 degradation" do
    @describetag :telemetry

    test "a raising provider degrades to static+ACL, loudly (telemetry + warning)" do
      toolset = unit_toolset("grant-unit")

      {:ok, entries, _} =
        Noizu.MCP.Toolset.catalog(toolset, ctx(principal("user-1")),
          persistence: Persistence.CrashProvider
        )

      assert "echo" in Enum.map(entries, & &1.definition.name)

      assert_receive {:persistence_error_telemetry, %{provider: Persistence.CrashProvider}}, 1_000
    end

    test "an error-returning provider degrades the same way" do
      toolset = unit_toolset("grant-unit")

      assert {:ok, entries, _} =
               Noizu.MCP.Toolset.catalog(toolset, ctx(principal("user-1")),
                 persistence: Persistence.ErrorProvider
               )

      assert entries != []
      assert_receive {:persistence_error_telemetry, %{provider: Persistence.ErrorProvider}}, 1_000
    end

    test "a corrupt stored set degrades to disabled-with-reason, server healthy" do
      # Force the table into existence, then hand-tamper a row: a grant whose
      # JSON is garbage.
      seed = put_grant(tool_overrides: %{})
      table = :noizu_mcp_persistence

      :ets.insert(
        table,
        {{"toolset_grants", "corrupt"}, "{not json", nil, {DateTime.utc_now(), 1}}
      )

      :ets.delete(table, {"toolset_grants", seed.id})

      toolset = unit_toolset("grant-unit")

      assert {:ok, entries, _} = Noizu.MCP.Toolset.catalog(toolset, ctx(principal("user-1")), [])
      assert "echo" in Enum.map(entries, & &1.definition.name)

      assert_receive {:persistence_error_telemetry, _metadata}, 1_000
    end

    test "the Disabled provider is a POLICY, not an outage — silent skip, no telemetry" do
      toolset = unit_toolset("grant-unit")

      assert {:ok, entries, _} =
               Noizu.MCP.Toolset.catalog(toolset, ctx(principal("user-1")),
                 persistence: :disabled
               )

      assert "echo" in Enum.map(entries, & &1.definition.name)
      refute_receive {:persistence_error_telemetry, _}
    end
  end

  # ── E2E: the same grant flow through a live session (AC-4.2) ─────────────

  describe "e2e grant flow through a session" do
    test "the granted principal sees echo_pro on the wire; nobody else does" do
      put_grant(
        toolset_slug: "grant-slice",
        tool_overrides: %{
          "secret_echo" => [
            %Override{op: :set_visible, value: true},
            %Override{op: :set_name, value: "echo_pro"}
          ]
        }
      )

      client = connect(Persistence.GrantServer)

      # tools/list AS the granted principal (claims-scoped deliver).
      names = claims_list_names(client, %{"sub" => "user-1"})
      assert "echo_pro" in names
      refute "secret_echo" in names

      # A claims-scoped request as another principal: base surface.
      other_names = claims_list_names(client, %{"sub" => "user-2"})
      refute "echo_pro" in other_names
      assert "echo" in other_names
    end
  end

  defp claims_list_names(client, claims) do
    :counters.add(client.counter, 1, 1)
    id = :counters.get(client.counter, 1)

    binary =
      IO.iodata_to_binary(JsonRpc.encode!(%Request{id: id, method: "tools/list", params: nil}))

    Session.deliver(client.session, binary, claims)

    assert {:ok, %{"tools" => tools}} = await(client, id, @await)
    Enum.map(tools, & &1["name"])
  end
end
