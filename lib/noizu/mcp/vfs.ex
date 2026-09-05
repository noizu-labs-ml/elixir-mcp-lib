defmodule Noizu.MCP.VFS do
  @moduledoc """
  Virtual filesystem behaviour for MCP servers.

  A VFS backend exposes a tree of nodes — directories, files, and control
  nodes — over paths (`"/etc/dev/state"`, `"/pm/tickets/PROJ-1"`, ...). The
  transport layer (M2) mounts a registered backend as extension operations
  (`vfs/stat`, `vfs/list`, ...); the Go FUSE daemon (M3) speaks those.

      defmodule MyApp.MCP.FS do
        use Noizu.MCP.VFS

        @impl true
        def stat("/", _ctx), do: {:ok, %Noizu.MCP.VFS{type: :dir, version: 1}}
        def stat(_path, _ctx), do: {:error, :enoent}

        @impl true
        def list("/", _cursor, _ctx), do: {:ok, [], nil}

        @impl true
        def read(path, ctx), do: ...
      end

  ## Nodes

  `c:stat/2`, `c:write/3`, and `c:create/3` return a `%Noizu.MCP.VFS{}` node:

    * `:type` — `:dir`, `:file`, or `:control`
    * `:size` — content size in bytes (0 for directories)
    * `:mtime` — last modification, unix milliseconds
    * `:version` — integer bumped on every write; the dispatcher embeds the
      backend's cache generation (see `Noizu.MCP.VFS.Cache`) so clients can key
      content caches on it
    * `:writable`, `:executable` — capability flags
    * `:xattrs` — backend-specific extended attributes (default `%{}`)

  ## Errors

  Callbacks return `{:error, errno}` with standard errno atoms: `:enoent`,
  `:eacces`, `:eexist`, `:erofs`, `:eisdir`, `:enotdir`, `:enosys`, and
  `:enotempty`. The M2 transport maps these to JSON-RPC codes. Pagination and
  cursor plumbing may surface `Noizu.MCP.Error.t()` structs instead — both are
  accepted everywhere.

  ## Defaults

  Read-only backends only implement `stat/2`, `list/3`, and `read/2`. Write
  (`write/3`, `create/3`, `remove/2`), `search/3`, and `xattr/2` have defaults:
  writes return `{:error, :enosys}`, `xattr/2` returns `{:ok, %{}}`. Override
  them to advertise write capability (see `Noizu.MCP.Server.VFS`).

  Every mount also serves a generated, read-only `/README.md` (see
  `Noizu.MCP.VFS.Readme`); a backend customizes its section there by
  overriding `__mcp_vfs__(:describe)` — default `nil` falls back to generic
  text. A backend that serves its own `/README.md` node wins outright.

  Conformance: any backend can be verified against the shared battery with
  `use Noizu.MCP.VFS.Conformance, backend: MyBackend, seed: {MyBackend, :seed}`.
  """

  alias Noizu.MCP.Ctx

  @enforce_keys [:type]
  defstruct type: :file,
            size: 0,
            mtime: 0,
            version: 1,
            writable: false,
            executable: false,
            xattrs: %{}

  @type type :: :dir | :file | :control
  @type errno ::
          :enoent | :eacces | :eexist | :erofs | :eisdir | :enotdir | :enosys | :enotempty
  @type t :: %__MODULE__{
          type: type(),
          size: non_neg_integer(),
          mtime: integer() | nil,
          version: non_neg_integer(),
          writable: boolean(),
          executable: boolean(),
          xattrs: map()
        }
  @type entry :: %{
          required(:name) => String.t(),
          required(:type) => type(),
          optional(:size) => non_neg_integer(),
          optional(:mtime) => integer() | nil,
          optional(:version) => non_neg_integer()
        }
  @type match :: %{
          required(:path) => String.t(),
          required(:line) => pos_integer(),
          required(:text) => String.t()
        }

  @doc "Metadata for a path."
  @callback stat(path :: String.t(), ctx :: Ctx.t()) :: {:ok, t()} | {:error, errno()}

  @doc "List the children of a directory, paginated."
  @callback list(path :: String.t(), cursor :: String.t() | nil, ctx :: Ctx.t()) ::
              {:ok, [entry()], next_cursor :: String.t() | nil}
              | {:error, errno() | Noizu.MCP.Error.t()}

  @doc "Read a file's content and its current version."
  @callback read(path :: String.t(), ctx :: Ctx.t()) ::
              {:ok, content :: binary(), version :: non_neg_integer()}
              | {:error, errno()}

  @doc "Overwrite an existing file."
  @callback write(path :: String.t(), data :: binary(), ctx :: Ctx.t()) ::
              {:ok, t()} | {:error, errno()}

  @doc "Create a new node. `data` is file content, or the `:dir` atom for a directory."
  @callback create(path :: String.t(), data :: binary() | :dir, ctx :: Ctx.t()) ::
              {:ok, t()} | {:error, errno()}

  @doc "Remove a file or an empty directory."
  @callback remove(path :: String.t(), ctx :: Ctx.t()) ::
              :ok | {:error, errno()}

  @doc "Grep-style line search over files under `root`, paginated."
  @callback search(root :: String.t(), query :: String.t(), ctx :: Ctx.t()) ::
              {:ok, [match()], next_cursor :: String.t() | nil}
              | {:error, errno() | Noizu.MCP.Error.t()}

  @doc "Extended attributes for a path. Defaults to `{:ok, %{}}`."
  @callback xattr(path :: String.t(), ctx :: Ctx.t()) ::
              {:ok, map()} | {:error, errno()}

  @doc false
  @callback __mcp_vfs__(:implemented) :: [atom()]

  @doc "Short markdown blurb for the backend's section in the mount's generated `/README.md` (see `Noizu.MCP.VFS.Readme`)."
  @callback __mcp_vfs__(:describe) :: String.t() | nil

  @optional_callbacks write: 3, create: 3, remove: 2, search: 3, xattr: 2

  # ⟦𓆒⟧ __using__
  defmacro __using__(_opts) do
    quote do
      @behaviour Noizu.MCP.VFS
      @before_compile Noizu.MCP.VFS
    end
  end

  # Records which optional callbacks the backend implemented, then fills the
  # rest with defaults. The implemented list is what `Noizu.MCP.Server.VFS`
  # reads to derive the `vfs_write` capability flag — a backend that defines
  # `write/3`, `create/3`, or `remove/2` is writable.
  # ⟦𓆒⟧ __before_compile__
  defmacro __before_compile__(env) do
    required = [stat: 2, list: 3, read: 2]
    optional = [write: 3, create: 3, remove: 2, search: 3, xattr: 2]

    implemented =
      (required ++ optional)
      |> Enum.filter(fn {fun, arity} -> Module.defines?(env.module, {fun, arity}) end)
      |> Enum.map(&elem(&1, 0))

    defaults =
      for {fun, arity} <- optional,
          not Module.defines?(env.module, {fun, arity}) do
        body =
          case fun do
            :xattr -> quote(do: {:ok, %{}})
            _ -> quote(do: {:error, :enosys})
          end

        args = List.duplicate(quote(do: _), arity)

        quote do
          @doc false
          def unquote(fun)(unquote_splicing(args)), do: unquote(body)
        end
      end

    # `__mcp_vfs__(:describe)` — a backend that defines its own clause keeps
    # it; everyone else gets the `nil` default.
    describe_default =
      unless Module.defines?(env.module, {:__mcp_vfs__, 1}) do
        quote do
          @doc false
          def __mcp_vfs__(:describe), do: nil
        end
      end

    quote do
      @doc false
      def __mcp_vfs__(:implemented), do: unquote(implemented)

      unquote_splicing(List.wrap(describe_default))

      unquote_splicing(defaults)
    end
  end
end
