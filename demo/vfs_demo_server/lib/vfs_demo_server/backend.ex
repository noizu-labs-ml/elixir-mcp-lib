defmodule VfsDemoServer.Backend do
  @moduledoc """
  The demo VFS backend: a full read-write `Noizu.MCP.VFS` implementation over
  `VfsDemoServer.Store` (seeded from `priv/seed/tree.yaml` at boot).

  Registered as the backend for the demo server's wire ops; `Features.VFS`
  wraps every call with cache + generation stamping, and mutations publish
  through `Noizu.MCP.Server.VFSPubSub`.
  """

  use Noizu.MCP.VFS

  alias VfsDemoServer.Store

  @impl true
  def stat(path, _ctx) do
    case Store.stat(path) do
      {:ok, node} -> {:ok, to_node(node)}
      error -> error
    end
  end

  @impl true
  def list(path, cursor, _ctx) do
    case Store.list(path, cursor) do
      {:ok, entries, next} -> {:ok, entries, next}
      error -> error
    end
  end

  @impl true
  def read(path, _ctx) do
    case Store.read(path) do
      {:ok, content, version} -> {:ok, content, version}
      error -> error
    end
  end

  @impl true
  def write(path, data, _ctx) do
    case Store.write(path, data) do
      {:ok, node} -> {:ok, to_node(node)}
      error -> error
    end
  end

  @impl true
  def create(path, data, _ctx) do
    case Store.create(path, data) do
      {:ok, node} -> {:ok, to_node(node)}
      error -> error
    end
  end

  @impl true
  def remove(path, _ctx) do
    Store.remove(path)
  end

  @impl true
  def search(root, query, _ctx) do
    case Store.search(root, query) do
      {:ok, matches} -> {:ok, matches, nil}
      error -> error
    end
  end

  @impl true
  def xattr(path, _ctx) do
    case Store.xattr(path) do
      {:ok, xattrs} -> {:ok, xattrs}
      error -> error
    end
  end

  defp to_node(%{
         type: type,
         content: content,
         version: version,
         mtime: mtime,
         xattrs: xattrs,
         writable: writable,
         executable: executable
       }) do
    %Noizu.MCP.VFS{
      type: type,
      size: if(type == :file, do: byte_size(content || ""), else: 0),
      mtime: mtime,
      version: version,
      writable: writable,
      executable: executable,
      xattrs: xattrs
    }
  end
end
