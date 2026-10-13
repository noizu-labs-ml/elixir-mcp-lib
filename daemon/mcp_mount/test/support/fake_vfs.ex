defmodule McpMount.Test.FakeVfs do
  @moduledoc """
  In-memory VFS tree used as the `McpMount.FakeConn` handler backend in unit
  tests. Plain maps + an Agent, no processes beyond the Agent. Supports a
  single page per list (cursor unused) — mounter pagination degrades fine.
  """

  def start_link(tree) do
    Agent.start_link(
      fn ->
        %{
          nodes: build(tree),
          next_id: 1,
          calls: [],
          fail_move: nil,
          sticky_move_failure: nil,
          fail_write: nil,
          fail_remove: nil,
          sticky_remove_failure: nil,
          markers: MapSet.new()
        }
      end,
      name: __MODULE__
    )
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

  # ── test observability / fault injection ──────────────────────────────────

  @doc "Every wire op this fake served, oldest first: [{method, params}]."
  def calls, do: Agent.get(__MODULE__, & &1.calls)

  @doc "Calls filtered to one method (params only), oldest first."
  def calls(method),
    do:
      Agent.get(
        __MODULE__,
        &(&1.calls
          |> Enum.reverse()
          |> Enum.flat_map(fn {m, p} -> if m == method, do: [p], else: [] end))
      )

  @doc "Make the next vfs/move fail with `reason` (an errno atom like :enosys, or {:code, -32601}). One-shot: cleared after the call."
  def fail_next_move(reason), do: Agent.update(__MODULE__, &%{&1 | fail_move: reason})

  @doc """
  Sticky failure for EVERY vfs/move until cleared with `set_move_failure(nil)`
  — drives the retry-until-parked cadence without one-shot races.
  """
  def set_move_failure(reason), do: Agent.update(__MODULE__, &%{&1 | sticky_move_failure: reason})

  @doc """
  Sticky failure for EVERY vfs/write until cleared with `set_write_failure(nil)`
  — keeps a local edit unpushed so remove-event save-aside tests stay
  deterministic (the ack would otherwise land before the injected remove).
  """
  def set_write_failure(reason), do: Agent.update(__MODULE__, &%{&1 | fail_write: reason})

  @doc "Make the next vfs/remove fail with `reason` (an errno atom or {:code, -32601}). One-shot: cleared after the call."
  def fail_next_remove(reason), do: Agent.update(__MODULE__, &%{&1 | fail_remove: reason})

  @doc """
  Sticky failure for EVERY vfs/remove until cleared with `set_remove_failure(nil)`
  — drives the delete retry-until-parked cadence without one-shot races.
  """
  def set_remove_failure(reason),
    do: Agent.update(__MODULE__, &%{&1 | sticky_remove_failure: reason})

  @doc ".confirm-delete command files currently recorded server-side (D2 marker intake)."
  def markers, do: Agent.get(__MODULE__, &MapSet.to_list(&1.markers))

  defp log_call(state, method, params) do
    Map.update!(state, :calls, &(&1 ++ [{method, params}]))
  end

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
    inner = fn
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

      "vfs/move", %{"from" => from, "to" => to} ->
        fail =
          Agent.get_and_update(__MODULE__, fn state ->
            # one-shot (fail_next_move) is consumed; sticky (set_move_failure)
            # survives every call until explicitly cleared with nil
            one_shot = state.fail_move

            state =
              if one_shot, do: %{state | fail_move: nil}, else: state

            {one_shot || state.sticky_move_failure, state}
          end)

        cond do
          match?({:code, _}, fail) ->
            {:error, %{code: elem(fail, 1), errno: nil, message: "fake refused"}}

          fail != nil ->
            {:error, fail}

          true ->
            move_tree(normalize(from), normalize(to))
        end

      # .confirm-delete command-file intake (VFS-FEATURES-DESIGN §2/D2):
      # records delete intent server-side, NEVER creates a page node
      "vfs/write", %{"path" => path, "data" => data} when is_binary(data) ->
        path = normalize(path)

        if String.ends_with?(path, "/.confirm-delete") do
          fail_write = Agent.get(__MODULE__, & &1.fail_write)

          if fail_write != nil do
            {:error, fail_write}
          else
            Agent.update(__MODULE__, &%{&1 | markers: MapSet.put(&1.markers, path)})
            {:ok, %{"version" => 1, "executable" => false}}
          end
        else
          write_file(path, data)
        end

      "vfs/write", %{"path" => path, "data" => data} ->
        write_file(normalize(path), data)

      "vfs/remove", %{"path" => path} ->
        path = normalize(path)

        fail =
          Agent.get_and_update(__MODULE__, fn state ->
            # one-shot (fail_next_remove) is consumed; sticky
            # (set_remove_failure) survives every call until cleared
            one_shot = state.fail_remove

            state =
              if one_shot, do: %{state | fail_remove: nil}, else: state

            {one_shot || state.sticky_remove_failure, state}
          end)

        cond do
          match?({:code, _}, fail) ->
            {:error, %{code: elem(fail, 1), errno: nil, message: "fake refused"}}

          fail != nil ->
            {:error, fail}

          true ->
            remove_tree(path)
        end

      _method, _params ->
        {:error, :enosys}
    end

    # log every served op so tests can assert "no vfs/move was ever sent"
    fn method, params ->
      Agent.update(__MODULE__, &log_call(&1, method, params))
      inner.(method, params)
    end
  end

  defp write_file(path, data) do
    fail_write = Agent.get(__MODULE__, & &1.fail_write)
    node = Agent.get(__MODULE__, & &1.nodes[path])

    cond do
      fail_write != nil ->
        {:error, fail_write}

      node == nil ->
        {:error, :enoent}

      node.type == :dir ->
        {:error, :eisdir}

      true ->
        version =
          Agent.get_and_update(__MODULE__, fn state ->
            state = update_in(state.nodes[path].content, fn _ -> data end)
            state = update_in(state.nodes[path].version, &(&1 + 1))
            {state.nodes[path].version, state}
          end)

        {:ok, %{"version" => version, "executable" => false}}
    end
  end

  # Delete semantics per the server half of design §2 + D2: a file removes
  # freely; a page-dir removes only when a .confirm-delete command file was
  # recorded for it (consumed by the successful delete) and it is childless.
  defp remove_tree(path) do
    Agent.get_and_update(__MODULE__, fn state ->
      node = state.nodes[path]
      marker = MapSet.member?(state.markers, path <> "/.confirm-delete")

      cond do
        node == nil ->
          {{:error, :enoent}, state}

        node.type == :dir and not marker ->
          {{:error, :eperm}, state}

        node.type == :dir ->
          if Enum.any?(state.nodes, fn {p, _} -> String.starts_with?(p, path <> "/") end) do
            {{:error, :enotempty}, state}
          else
            {_, st} = pop_in(state.nodes[path])
            st = %{st | markers: MapSet.delete(st.markers, path <> "/.confirm-delete")}
            {{:ok, %{"removed" => path}}, st}
          end

        true ->
          {_, st} = pop_in(state.nodes[path])
          {{:ok, %{"removed" => path}}, st}
      end
    end)
  end

  defp move_tree(from, to) do
    Agent.get_and_update(__MODULE__, fn state ->
      cond do
        state.nodes[from] == nil ->
          {{:error, :enoent}, state}

        Map.has_key?(state.nodes, to) ->
          {{:error, :eexist}, state}

        # rename a dir into itself: corrupting shape, refuse like the
        # elixir-mcp fixture does (:eio, the EINVAL stand-in)
        String.starts_with?(to, from <> "/") ->
          {{:error, :eio}, state}

        true ->
          prefix = from <> "/"

          moved =
            for {p, _node} <- state.nodes,
                p == from or String.starts_with?(p, prefix),
                do: p

          version = state.nodes[from].version

          nodes =
            Enum.reduce(moved, state.nodes, fn p, acc ->
              acc
              |> Map.delete(p)
              |> Map.put(renamed(p, from, to), Map.fetch!(state.nodes, p))
            end)

          {{:ok, %{"version" => version, "executable" => false}}, %{state | nodes: nodes}}
      end
    end)
  end

  defp renamed(p, from, to),
    do: to <> binary_part(p, byte_size(from), byte_size(p) - byte_size(from))

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
