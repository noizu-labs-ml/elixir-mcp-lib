defmodule VfsDemoServer.Seed do
  @moduledoc """
  Loads the YAML seed tree (`priv/seed/tree.yaml`) into node maps.

  Seed entries: `{path, type: dir|file, content?, mode?, xattrs?}`. Entries are
  ordered parents-first, so `/etc` precedes `/etc/dev/flag`.
  """

  def load(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{"tree" => entries}} when is_list(entries) ->
        build(entries)

      other ->
        raise ArgumentError, "invalid seed file at #{inspect(path)}: #{inspect(other)}"
    end
  end

  def build(entries) do
    root = node("/", :dir, nil, nil, %{})

    [root | Enum.map(entries, &build_node/1)]
    |> Enum.sort_by(fn node -> length(String.split(node.path, "/", trim: true)) end)
  end

  defp build_node(%{"path" => path} = entry) do
    case entry["type"] do
      "dir" -> node(normalize!(path), :dir, nil, entry["mode"], xattrs(entry))
      "file" -> node(normalize!(path), :file, content(entry), entry["mode"], xattrs(entry))
      other -> raise ArgumentError, "invalid seed type #{inspect(other)} for #{path}"
    end
  end

  defp build_node(entry), do: raise(ArgumentError, "seed entry missing path: #{inspect(entry)}")

  defp node(path, type, content, mode, xattrs) do
    mode = mode || if(type == :dir, do: 0o755, else: 0o644)

    %{
      path: path,
      type: type,
      content: if(type == :file, do: content || "", else: nil),
      mode: mode,
      version: 1,
      mtime: System.system_time(:millisecond),
      xattrs: xattrs,
      writable: true,
      executable: Bitwise.band(mode, 0o111) != 0
    }
  end

  defp normalize!(path) do
    case VfsDemoServer.Paths.normalize(path) do
      {:error, errno} -> raise ArgumentError, "invalid seed path #{inspect(path)}: #{errno}"
      normalized -> normalized
    end
  end

  defp content(%{"content" => content}) when is_binary(content), do: content
  defp content(%{"content" => other}), do: to_string(other)
  defp content(_), do: ""

  defp xattrs(%{"xattrs" => x}) when is_map(x), do: Map.new(x, fn {k, v} -> {to_string(k), v} end)
  defp xattrs(_), do: %{}
end
