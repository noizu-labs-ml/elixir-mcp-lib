defmodule McpMount.Test.FakeVfs do
  @moduledoc """
  In-memory VFS tree used as the `McpMount.FakeConn` handler backend in unit
  tests. Plain maps + an Agent, no processes beyond the Agent. Supports a
  single page per list (cursor unused) — mounter pagination degrades fine.
  """

  def start_link(tree) do
    Agent.start_link(fn -> %{nodes: build(tree), next_id: 1} end, name: __MODULE__)
  end

  defp build(tree), do: Map.new(tree, fn {path, node} -> {normalize(path), node} end)

  def child_spec(tree), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [tree]}}

  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  @doc "Remote mutation without any event delivery (test drives that itself)."
  def write(path, content), do: mutation(:write, path, content)

  defp mutation(:write, path, content) do
    Agent.update(__MODULE__, fn state ->
      node = state.nodes[path]

      if node && node.type == :file do
        put_in(state.nodes[path].content, content)
        |> update_in([:nodes, path, :version], &(&1 + 1))
      else
        state
      end
    end)
  end

  @doc "Build a FakeConn handler fun over this tree (wire-shaped results)."
  def handler do
    fn
      "vfs/ping", _params ->
        {:ok, %{"pong" => true}}

      "vfs/list", %{"path" => path} ->
        children =
          __MODULE__
          |> Agent.get(& &1.nodes)
          |> Enum.filter(fn {p, _node} -> parent(p) == normalize(path) end)
          |> Enum.sort()
          |> Enum.map(fn {p, node} ->
            %{"name" => basename(p), "type" => to_string(node.type), "version" => node.version}
          end)

        {:ok, %{"entries" => children}}

      "vfs/read", %{"path" => path} ->
        node = Agent.get(__MODULE__, & &1.nodes[normalize(path)])

        cond do
          node == nil -> {:error, :enoent}
          node.type == :dir -> {:error, :eisdir}
          true -> {:ok, %{"content" => node.content, "version" => node.version}}
        end

      "vfs/stat", %{"path" => path} ->
        node = Agent.get(__MODULE__, & &1.nodes[normalize(path)])

        if node do
          {:ok,
           %{
             "type" => to_string(node.type),
             "version" => node.version,
             "executable" => false
           }}
        else
          {:error, :enoent}
        end

      "vfs/write", %{"path" => path, "data" => data} ->
        node = Agent.get(__MODULE__, & &1.nodes[normalize(path)])

        cond do
          node == nil ->
            {:error, :enoent}

          node.type == :dir ->
            {:error, :eisdir}

          true ->
            version =
              Agent.get_and_update(__MODULE__, fn state ->
                state = update_in(state.nodes[normalize(path)].content, fn _ -> data end)
                state = update_in(state.nodes[normalize(path)].version, &(&1 + 1))
                {state.nodes[normalize(path)].version, state}
              end)

            {:ok, %{"version" => version, "executable" => false}}
        end

      "vfs/create", %{"path" => path, "data" => data} ->
        path = normalize(path)

        case Agent.get(__MODULE__, & &1.nodes[path]) do
          nil ->
            node =
              if data == nil,
                do: %{type: :dir, version: 1},
                else: %{type: :file, content: data, version: 1}

            Agent.update(__MODULE__, fn state ->
              parent = parent(path)

              if parent != nil and !Map.has_key?(state.nodes, parent) do
                state
              else
                put_in(state.nodes[path], node)
              end
            end)

            {:ok, %{"version" => 1, "executable" => false}}

          _existing ->
            {:error, :eexist}
        end

      _method, _params ->
        {:error, :enosys}
    end
  end

  defp normalize("/"), do: "/"

  defp normalize("/" <> _ = p) do
    trimmed = String.trim_trailing(p, "/")
    "/" <> String.trim_leading(trimmed, "/")
  end

  defp parent("/"), do: nil

  defp parent(p) do
    case String.split(p, "/", trim: true) do
      [_] -> "/"
      parts -> "/" <> Enum.join(Enum.drop(parts, -1), "/")
    end
  end

  defp basename(p), do: p |> String.split("/", trim: true) |> List.last()
end
