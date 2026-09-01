defmodule VfsDemoServer.Paths do
  @moduledoc false

  @doc "Normalize a VFS path: absolute, no trailing slash (except root), no empties."
  def normalize("/" <> _ = path) do
    trimmed = String.trim_trailing(path, "/")

    if trimmed == "",
      do: "/",
      else: "/" <> (trimmed |> String.trim_leading("/") |> String.replace(~r{//+}, "/"))
  end

  def normalize(path) when is_binary(path), do: {:error, :enoent}
  def normalize(_), do: {:error, :enoent}

  @doc "Parent directory of `path` (`nil` for the root)."
  def parent("/"), do: nil

  def parent(path) do
    case String.split(path, "/", trim: true) do
      [_] -> "/"
      parts -> "/" <> Enum.join(Enum.drop(parts, -1), "/")
    end
  end

  def basename("/"), do: "/"

  def basename(path) do
    path |> String.split("/", trim: true) |> List.last()
  end

  @doc "True when `path` is `ancestor` itself or lives under it."
  def under?(_path, "/"), do: true

  def under?(path, ancestor) do
    path == ancestor or String.starts_with?(path, ancestor <> "/")
  end
end
