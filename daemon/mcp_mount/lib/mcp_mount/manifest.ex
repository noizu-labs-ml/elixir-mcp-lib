defmodule McpMount.Manifest do
  @moduledoc """
  `.mcp-mount/manifest.json` — the mounter's sync state: `{path -> {version,
  mode, size}}` for every materialized file. All writes are atomic (temp file
  + rename). The `.mcp-mount` directory is created mode 0700.
  """

  @dir ".mcp-mount"
  @filename "manifest.json"

  @doc "Path of the `.mcp-mount` directory under `mount`."
  def dir(mount), do: Path.join(mount, @dir)

  @doc "Create the mount dir and `.mcp-mount` (0700) if missing."
  def prepare(mount) do
    File.mkdir_p!(mount)
    File.mkdir_p!(dir(mount))
    File.chmod!(dir(mount), 0o700)
    :ok
  end

  @doc "Read the manifest: `%{rel_path => %{version:, mode:, size:}}`. Missing file -> `%{}`."
  def read(mount) do
    path = Path.join(dir(mount), @filename)

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} ->
            Map.new(map, fn {path, entry} ->
              {path,
               %{
                 version: entry["version"],
                 mode: entry["mode"],
                 size: entry["size"]
               }}
            end)

          {:error, _} ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end

  @doc "Atomically write the manifest (temp + rename)."
  def write(mount, entries) when is_map(entries) do
    entries =
      Map.new(entries, fn {path, e} ->
        {path, %{"version" => e.version, "mode" => e.mode, "size" => e.size}}
      end)

    body = Jason.encode!(entries)

    tmp = Path.join(dir(mount), @filename <> ".tmp")
    File.write!(tmp, body)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, Path.join(dir(mount), @filename))
    :ok
  end

  @doc "True when a relative path is mounter-internal and never synced."
  def ignored?("." <> _), do: true

  def ignored?(rel) do
    String.starts_with?(rel, @dir <> "/") or
      rel == @dir or
      String.contains?(rel, ".conflict-")
  end
end
