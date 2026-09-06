defmodule Noizu.MCP.Engine.MixTaskTest do
  @moduledoc "`mix mcp.engine` argument handling (PRD-11 §7 mix_task_test.exs, AC-11.14)."

  use ExUnit.Case, async: false

  alias Mix.Tasks.Mcp.Engine, as: Task

  describe "parse_args!/1" do
    test "defaults" do
      opts = Task.parse_args!([])
      assert opts[:attach] == []
      assert Task.bind_address(opts) == :any
    end

    test "--no-auth pins the bind to loopback" do
      opts = Task.parse_args!(["--no-auth"])
      assert Task.bind_address(opts) == {127, 0, 0, 1}
    end

    test "--attach parses stdio specs (shell-split command, FR-11.18)" do
      opts =
        Task.parse_args!(["--attach", "github=stdio:npx -y @modelcontextprotocol/server-github"])

      assert [
               %{
                 "name" => "github",
                 "transport" => "stdio",
                 "command" => "npx -y @modelcontextprotocol/server-github",
                 "enabled" => true
               }
             ] = opts[:attach]
    end

    test "--attach parses http specs" do
      opts = Task.parse_args!(["--attach", "remote=http:https://mcp.example.com/mcp"])

      assert [
               %{
                 "name" => "remote",
                 "transport" => "http",
                 "url" => "https://mcp.example.com/mcp"
               }
             ] = opts[:attach]
    end

    test "--attach is repeatable" do
      opts =
        Task.parse_args!(["--attach", "a=stdio:cmd", "--attach", "b=http:http://x.example"])

      assert length(opts[:attach]) == 2
    end

    test "a malformed --attach spec raises" do
      assert_raise(Mix.Error, ~r/name=stdio:CMD/, fn ->
        Task.parse_args!(["--attach", "bogus"])
      end)

      assert_raise(Mix.Error, ~r/stdio:CMD/, fn ->
        Task.parse_args!(["--attach", "name=grpc:host"])
      end)
    end

    test "invalid options raise" do
      assert_raise(Mix.Error, ~r/Invalid options/, fn ->
        Task.parse_args!(["--wat"])
      end)
    end
  end
end
