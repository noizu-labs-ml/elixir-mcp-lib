defmodule Noizu.MCP.ACL.Providers.ScopesTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.ACL.Provider
  alias Noizu.MCP.ACL.Providers.Scopes
  alias Noizu.MCP.ACL.Resource
  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.Ctx

  @ctx %Ctx{server: nil, assigns: %{}}

  defp principal(scopes) when is_list(scopes),
    do: %Principal{subject: "user-1", authenticator: :test, granted_scopes: MapSet.new(scopes)}

  defp resource(kind \\ :tool, id \\ "tool_x"), do: %Resource{kind: kind, id: id}

  defp rules,
    do: [
      %{scope: "mcp", resource: "tools:**", actions: [:call]},
      %{scope: "read:all", resource: "content:/resources/**", actions: [:read, :list]},
      %{scope: "pm:*", resource: "tools:project_*", actions: [:call]}
    ]

  describe "check/5 — rule matching" do
    test "a matching rule allows" do
      opts = [rules: rules()]

      assert Scopes.check(principal(["mcp"]), resource(:tool, "tools:echo"), :call, @ctx, opts) ==
               :allow
    end

    test "no matching rule denies" do
      opts = [rules: rules()]

      assert Scopes.check(principal(["other"]), resource(:tool, "tools:echo"), :call, @ctx, opts) ==
               :deny
    end

    test "matching resource but wrong action denies" do
      opts = [rules: rules()]

      assert Scopes.check(
               principal(["read:all"]),
               resource(:resource, "content:/resources/a/1"),
               :write,
               @ctx,
               opts
             ) == :deny
    end
  end

  describe "check/5 — glob patterns (* vs **)" do
    test "`**` matches any run of segments (suffix)" do
      opts = [rules: [%{scope: "mcp", resource: "content:/resources/**", actions: [:read]}]]

      assert Scopes.check(
               principal(["mcp"]),
               resource(:resource, "content:/resources/a/b/c"),
               :read,
               @ctx,
               opts
             ) == :allow

      # Zero segments after the prefix also matches.
      assert Scopes.check(
               principal(["mcp"]),
               resource(:resource, "content:/resources"),
               :read,
               @ctx,
               opts
             ) == :allow

      # Outside the prefix does not.
      assert Scopes.check(
               principal(["mcp"]),
               resource(:resource, "content:/elsewhere/x"),
               :read,
               @ctx,
               opts
             ) == :deny
    end

    test "`*` matches exactly one segment, any characters within it" do
      opts = [rules: [%{scope: "mcp", resource: "tools:project_*", actions: [:call]}]]

      assert Scopes.check(
               principal(["mcp"]),
               resource(:tool, "tools:project_x"),
               :call,
               @ctx,
               opts
             ) ==
               :allow

      assert Scopes.check(
               principal(["mcp"]),
               resource(:tool, "tools:project_x/y"),
               :call,
               @ctx,
               opts
             ) == :deny

      assert Scopes.check(principal(["mcp"]), resource(:tool, "tools:project"), :call, @ctx, opts) ==
               :deny
    end

    test "segments match literally otherwise" do
      opts = [rules: [%{scope: "mcp", resource: "tools:echo", actions: [:call]}]]

      assert Scopes.check(principal(["mcp"]), resource(:tool, "tools:echo"), :call, @ctx, opts) ==
               :allow

      assert Scopes.check(principal(["mcp"]), resource(:tool, "tools:echo2"), :call, @ctx, opts) ==
               :deny
    end
  end

  describe "check/5 — scope intersection" do
    test "rule scope must be among the granted scopes" do
      opts = [rules: [%{scope: "content:read", resource: "tools:**", actions: [:call]}]]

      assert Scopes.check(principal(["mcp"]), resource(:tool, "tools:echo"), :call, @ctx, opts) ==
               :deny

      assert Scopes.check(
               principal(["content:read"]),
               resource(:tool, "tools:echo"),
               :call,
               @ctx,
               opts
             ) ==
               :allow
    end

    test "rule scope may itself be a trailing-* glob" do
      opts = [rules: [%{scope: "pm:*", resource: "tools:**", actions: [:call]}]]

      assert Scopes.check(
               principal(["pm:read", "mcp"]),
               resource(:tool, "tools:echo"),
               :call,
               @ctx,
               opts
             ) ==
               :allow

      # A principal holding NO scopes matches nothing.
      assert Scopes.check(principal([]), resource(:tool, "tools:echo"), :call, @ctx, opts) ==
               :deny
    end
  end

  describe "check/5 — fail-closed" do
    test "no rules denies everything" do
      assert Scopes.check(principal(["mcp"]), resource(), :call, @ctx, rules: []) == :deny
      assert Scopes.check(principal(["mcp"]), resource(), :call, @ctx, []) == :deny
    end

    test "non-Principal subject raises (protocol fail-closed, D4)" do
      assert_raise ArgumentError, ~r/explicit participants/, fn ->
        Scopes.check("user-1", resource(), :call, @ctx, rules: rules())
      end

      assert_raise ArgumentError, ~r/explicit participants/, fn ->
        Scopes.check(nil, resource(), :call, @ctx, rules: rules())
      end
    end

    test "malformed rule raises as a configuration error" do
      assert_raise ArgumentError, ~r/rules must be/, fn ->
        Scopes.check(principal(["mcp"]), resource(), :call, @ctx, rules: [%{scope: "mcp"}])
      end

      assert_raise ArgumentError, ~r/rules must be/, fn ->
        Scopes.check(principal(["mcp"]), resource(), :call, @ctx,
          rules: [%{scope: "mcp", resource: "tools:**", actions: []}]
        )
      end
    end
  end

  describe "filter_entries/4 (via the registered provider)" do
    defp entry(name),
      do: %Noizu.MCP.Toolset.Entry{
        definition: %Noizu.MCP.Types.Tool{name: name, description: "#{name} fixture"},
        visible: true,
        callable: true
      }

    defp entries,
      do: [entry("tools:echo"), entry("tools:admin_purge"), entry("content:/resources/a")]

    test "hides entries no rule covers, preserving order" do
      subject = principal(["read:all"])

      filtered =
        Provider.filter_entries(entries(), nil, %{@ctx | auth: subject},
          acl:
            {Scopes,
             rules: [%{scope: "read:all", resource: "content:/resources/**", actions: [:call]}]}
        )

      assert [%{visible: true, callable: true}] =
               filtered
               |> Enum.filter(& &1.visible)

      denied = Enum.find(filtered, &(&1.definition.name == "tools:echo"))
      assert %{visible: false, callable: false, reason: {:acl, Scopes}} = denied
    end

    test "a crashing check (malformed rule) denies the whole set, fail-closed" do
      subject = principal(["mcp"])

      filtered =
        Provider.filter_entries(entries(), nil, %{@ctx | auth: subject},
          acl: {Scopes, rules: [%{scope: "mcp"}]}
        )

      assert Enum.all?(filtered, &(&1.visible == false and &1.callable == false))
    end

    test "through the protocol: check consults the per-call registered provider" do
      subject = principal(["mcp"])

      assert Noizu.MCP.ACL.check(subject, resource(:tool, "tools:echo"), :call, @ctx,
               acl: {Scopes, rules: rules()}
             ) == :allow

      assert Noizu.MCP.ACL.check(principal([]), resource(:tool, "tools:echo"), :call, @ctx,
               acl: {Scopes, rules: rules()}
             ) == :deny
    end
  end
end
