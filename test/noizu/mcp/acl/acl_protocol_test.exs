defmodule Noizu.MCP.ACL.ACLProtocolTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.{ACL, Ctx, Error}
  alias Noizu.MCP.ACL.Resource
  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.Fixtures

  @subject %Principal{subject: "user-1", authenticator: :test}
  @ctx %Ctx{server: nil, assigns: %{}}

  defp resource(kind \\ :tool, id \\ "tool_x"), do: %Resource{kind: kind, id: id}

  defp telemetry_ref do
    ref = make_ref()

    # One UNIQUE id per event: telemetry silently ignores a re-attach of an
    # existing id, so a shared id would leave all but the first event deaf.
    for event <- [
          [:noizu_mcp, :acl, :check],
          [:noizu_mcp, :acl, :error],
          [:noizu_mcp, :acl, :stale_verdict]
        ] do
      :telemetry.attach(
        {ref, event},
        event,
        fn e, measurements, metadata, _ ->
          send(self(), {:acl_telemetry, e, measurements, metadata})
        end,
        nil
      )
    end

    on_exit(fn ->
      for event <- [
            [:noizu_mcp, :acl, :check],
            [:noizu_mcp, :acl, :error],
            [:noizu_mcp, :acl, :stale_verdict]
          ] do
        :telemetry.detach({ref, event})
      end
    end)
  end

  describe "protocol + Principal impl (FR-2.7)" do
    test "consults the per-call provider: allow" do
      assert ACL.check(@subject, resource(), :call, @ctx, acl: Fixtures.ACL.AllowAllProvider) ==
               :allow
    end

    test "consults the per-call provider: deny" do
      assert ACL.check(@subject, resource(), :call, @ctx, acl: ACL.Providers.DenyAll) == :deny
    end

    test "consults the ctx server's registered provider" do
      ctx = %Ctx{server: Fixtures.ACL.DenyAllServer, assigns: %{}}
      assert ACL.check(@subject, resource(), :call, ctx, []) == :deny
    end

    test "no provider configured ⇒ :allow (inert, D4)" do
      assert ACL.check(@subject, resource(), :call, @ctx, []) == :allow
    end

    test "garbage verdicts normalize to :deny (D5)" do
      assert ACL.check(@subject, resource(), :call, @ctx,
               acl: Fixtures.ACL.GarbageVerdictProvider
             ) ==
               :deny
    end

    test "ungoverned kinds raise at check time (§4.7)" do
      assert_raise ArgumentError, ~r/does not govern resource kind :tool/, fn ->
        ACL.check(@subject, resource(:tool), :call, @ctx, acl: Fixtures.ACL.PromptOnlyProvider)
      end

      # The kind it DOES govern passes through.
      assert ACL.check(@subject, resource(:prompt, "p1"), :call, @ctx,
               acl: Fixtures.ACL.PromptOnlyProvider
             ) == :allow
    end

    test "subjects must be explicit participants: the Any impl is fail-closed (D4)" do
      assert_raise ArgumentError, ~r/explicit participants/, fn ->
        ACL.check("user-1", resource(), :call, @ctx, acl: Fixtures.ACL.AllowAllProvider)
      end

      assert_raise ArgumentError, ~r/explicit participants/, fn ->
        ACL.check(nil, resource(), :call, @ctx, [])
      end
    end
  end

  describe "Resource struct (§4.6)" do
    test "kind and id are enforced" do
      # Elixir 1.20's struct!/2 raises ArgumentError for missing enforced keys.
      assert_raise ArgumentError, fn -> struct!(Resource, %{}) end
    end

    test "fields" do
      r = resource(:tool, "echo")
      assert r.kind == :tool
      assert r.id == "echo"
    end
  end

  describe "check_all/5" do
    test "DEFAULT impl fans out into check/5 and keys by id" do
      verdicts =
        ACL.Provider.check_all(
          Fixtures.ACL.AllowAllProvider,
          @subject,
          [resource(:tool, "a"), resource(:tool, "b")],
          :call,
          @ctx,
          []
        )

      assert verdicts == %{"a" => :allow, "b" => :allow}
    end

    test "batch override wins: PartialBatchProvider omits absent tools" do
      verdicts =
        ACL.Provider.check_all(
          Fixtures.ACL.PartialBatchProvider,
          @subject,
          [resource(:tool, "tool_a"), resource(:tool, "tool_b"), resource(:tool, "tool_c")],
          :call,
          @ctx,
          []
        )

      assert verdicts == %{"tool_a" => :deny, "tool_b" => :allow}
      refute Map.has_key?(verdicts, "tool_c")
    end

    test "extra ids are stale policy: ignored with a debug event (Q1)" do
      telemetry_ref()

      assert %{"a" => :allow} =
               ACL.Provider.check_all(
                 Fixtures.ACL.StaleBatchProvider,
                 @subject,
                 [resource(:tool, "a")],
                 :call,
                 @ctx,
                 []
               )

      assert_receive {:acl_telemetry, [:noizu_mcp, :acl, :stale_verdict], %{},
                      %{provider: Fixtures.ACL.StaleBatchProvider, stale: stale}}

      assert Enum.sort(stale) == ["another_ghost", "ghost_tool"]
    end
  end

  describe "built-in providers (§4.6)" do
    test "Disabled allows everything" do
      assert ACL.Providers.Disabled.check(@subject, resource(), :call, @ctx, []) == :allow
    end

    test "DenyAll denies everything" do
      assert ACL.Providers.DenyAll.check(@subject, resource(), :call, @ctx, []) == :deny
    end

    test "both declare the Provider behaviour" do
      for provider <- [ACL.Providers.Disabled, ACL.Providers.DenyAll] do
        behaviours =
          provider.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

        assert Noizu.MCP.ACL.Provider in behaviours
        assert function_exported?(provider, :check, 5)
      end
    end

    test "supported_kinds defaults to all four built-ins" do
      assert ACL.Provider.supported_kinds(ACL.Providers.DenyAll) ==
               [:tool, :toolset, :prompt, :resource]

      assert ACL.Provider.supported_kinds(Fixtures.ACL.PromptOnlyProvider) == [:prompt]
    end
  end

  describe "telemetry (FR-2.11)" do
    test "each check emits [:noizu_mcp, :acl, :check] with provider + verdict" do
      telemetry_ref()

      assert :deny =
               ACL.check(@subject, resource(), :call, @ctx,
                 acl: Fixtures.ACL.GarbageVerdictProvider
               )

      assert_receive {:acl_telemetry, [:noizu_mcp, :acl, :check], %{duration: duration},
                      %{provider: Fixtures.ACL.GarbageVerdictProvider, verdict: :deny}}

      assert is_integer(duration)
    end
  end

  describe "Error.forbidden/2 (FR-2.6)" do
    test "code -32000, reason :forbidden" do
      error = Error.forbidden()
      assert error.code == -32_000
      assert error.reason == :forbidden
      assert error.message == "Forbidden"

      error = Error.forbidden("nope", %{"why" => "acl"})
      assert error.message == "nope"
      assert error.data == %{"why" => "acl"}
    end

    test "round-trips through the wire map" do
      assert %{"code" => -32_000} = Error.to_map(Error.forbidden("nope"))
      assert Error.from_map(%{"code" => -32_000, "message" => "x"}).reason == :forbidden
    end
  end
end
