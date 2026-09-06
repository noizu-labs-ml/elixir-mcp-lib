defmodule Noizu.MCP.Server.Dataset do
  @moduledoc """
  A relation a server projects into SQL via the `sql/*` methods (PRD-9 §4.1).

  A dataset is for tabular data a server holds that is *not* naturally a tool
  call — prompt versions, sessions, artifacts, a directory tree, an upstream
  registry. Tools, prompts and resources already project into SQL without any
  help (see `Noizu.MCP.SQL.Schema`); a dataset is the escape hatch for
  everything else.

      defmodule MyApp.MCP.Sessions do
        use Noizu.MCP.Server.Dataset

        @impl true
        def info do
          %{
            name: "sessions",
            title: "Sessions",
            description: "Live sessions for the calling principal.",
            primary_key: ["id"],
            writable: false
          }
        end

        @impl true
        def columns do
          [
            %{name: "id", type: :uuid, nullable: false, description: "Session id"},
            %{name: "started_at", type: :timestamptz, nullable: false, description: nil}
          ]
        end

        @impl true
        def scan(_args, ctx, _opts), do: {:ok, MyApp.sessions_for(ctx.auth), nil}
      end

  Register it beside the server's tools:

      defmodule MyApp.MCP do
        use Noizu.MCP.Server, name: "myapp", version: "1.0.0"

        dataset MyApp.MCP.Sessions
      end

  ## Participation is explicit

  There is no `Any` implementation and no runtime probing (D4). A module is a
  dataset because it `use`s this behaviour, and a server serves it because it
  was named in `dataset/2`. The optional write callbacks are detected at
  compile time with `Module.defines?/2` and published through
  `__mcp_dataset__(:ops)` — an op whose callback is absent answers
  `method_not_found`, naming the relation and the op.

  ## The qual contract

  `scan/3` receives quals, a column list, a sort, a limit and a cursor, and MAY
  ignore any of them: the caller re-checks every qual locally. See
  `Noizu.MCP.SQL.Quals` for the normative statement. The only prohibition is
  returning rows a qual the dataset *did* apply would have excluded.

  ## Rows are maps

  `scan/3`, `insert/2` and `update/3` return and receive maps keyed by column
  name. Positional wire rows are built by `Noizu.MCP.Server.Features.SQL`
  against the declared column order, filling `nil` for any column a dataset
  omits; datasets never build positional rows themselves.

  ## Failure is per-relation

  A dataset that raises in `scan/3` yields an error for that relation only
  (D5). `sql/schema` and every other dataset on the same server keep working
  in the same session.
  """

  alias Noizu.MCP.SQL.Types

  @type column :: %{
          required(:name) => String.t(),
          required(:type) => Types.t(),
          optional(:nullable) => boolean(),
          optional(:description) => String.t() | nil
        }

  @type qual :: Noizu.MCP.SQL.Quals.t()

  @type scan_opts :: %{
          optional(:quals) => [qual()],
          optional(:columns) => [String.t()],
          optional(:sort) => [{String.t(), :asc | :desc}],
          optional(:limit) => pos_integer(),
          optional(:cursor) => String.t()
        }

  @type row :: %{String.t() => term()}

  @type info :: %{
          required(:name) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:primary_key) => [String.t()],
          optional(:writable) => boolean()
        }

  @doc "Static column list. Called at schema time; must be pure and cheap."
  @callback columns() :: [column()]

  @doc "Descriptive metadata: name, title, description, primary_key, writable."
  @callback info() :: info()

  @doc """
  Scan the relation. `opts` carries quals/columns/sort/limit/cursor; a dataset
  MAY ignore any of them — the caller re-checks every qual — but MUST NOT
  return rows excluded by a qual it claims to have applied.
  """
  @callback scan(args :: map(), ctx :: Noizu.MCP.Ctx.t(), opts :: scan_opts()) ::
              {:ok, [row()], cursor :: String.t() | nil} | {:error, Noizu.MCP.Error.t()}

  @doc "Insert rows. Best-effort: return the rows actually written."
  @callback insert(rows :: [row()], ctx :: Noizu.MCP.Ctx.t()) ::
              {:ok, [row()]} | {:error, Noizu.MCP.Error.t()}

  @doc "Apply `changes` to every row matching `quals`. Returns the rows written."
  @callback update(quals :: [qual()], changes :: row(), ctx :: Noizu.MCP.Ctx.t()) ::
              {:ok, [row()]} | {:error, Noizu.MCP.Error.t()}

  @doc "Delete every row matching `quals`. Returns the number deleted."
  @callback delete(quals :: [qual()], ctx :: Noizu.MCP.Ctx.t()) ::
              {:ok, non_neg_integer()} | {:error, Noizu.MCP.Error.t()}

  @doc false
  @callback __mcp_dataset__(atom()) :: term()

  @optional_callbacks insert: 2, update: 3, delete: 2

  @write_callbacks [insert: 2, update: 3, delete: 2]

  @doc """
  Make the module a dataset: injects the behaviour, a `__mcp_dataset__/1`
  introspection function, and a compile-time validation of `columns/0` against
  `Noizu.MCP.SQL.Types`.

  Options are stored verbatim under `__mcp_dataset__(:opts)`; the library reads
  none of them today, and `dataset/2`'s registration options are the supported
  way to override a dataset's wire name or hide it.
  """
  defmacro __using__(opts \\ []) do
    quote do
      @behaviour Noizu.MCP.Server.Dataset
      @__mcp_dataset_opts__ unquote(opts)
      @before_compile Noizu.MCP.Server.Dataset
      @after_compile Noizu.MCP.Server.Dataset
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :__mcp_dataset_opts__) || []

    ops =
      for {name, arity} <- @write_callbacks,
          Module.defines?(env.module, {name, arity}),
          do: name

    quote do
      @impl Noizu.MCP.Server.Dataset
      def __mcp_dataset__(:ops), do: unquote(ops)
      def __mcp_dataset__(:opts), do: unquote(Macro.escape(opts))
      def __mcp_dataset__(:writable?), do: unquote(ops != [])
    end
  end

  @doc false
  # Column validation runs after compile, where `columns/0` is callable: a
  # malformed column list is a build failure, not a runtime surprise (D5 —
  # config errors that can fail at compile time do).
  def __after_compile__(env, _bytecode) do
    module = env.module

    exports = module.module_info(:exports)

    unless Keyword.has_key?(exports, :columns) and Keyword.has_key?(exports, :info) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "#{inspect(module)}: use Noizu.MCP.Server.Dataset requires columns/0 and info/0"
    end

    validate_columns!(module, module.columns())
    validate_info!(module, module.info())
  end

  @doc """
  Validate a column list against the type vocabulary. Raises `CompileError`
  with the offending entry; returns the normalized list otherwise.
  """
  @spec validate_columns!(module(), term()) :: [column()]
  def validate_columns!(module, columns) when is_list(columns) do
    if columns == [] do
      compile_error!(module, "columns/0 must declare at least one column")
    end

    normalized = Enum.map(columns, &validate_column!(module, &1))

    duplicates =
      normalized
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    unless duplicates == [] do
      compile_error!(module, "columns/0 declares duplicate column names: #{inspect(duplicates)}")
    end

    normalized
  end

  def validate_columns!(module, other) do
    compile_error!(module, "columns/0 must return a list, got: #{inspect(other)}")
  end

  defp validate_column!(module, %{name: name, type: type} = column) when is_binary(name) do
    unless Types.valid?(type) do
      compile_error!(
        module,
        "column #{inspect(name)} declares unknown type #{inspect(type)} — expected one of " <>
          "#{inspect(Types.vocabulary())} or {:enum, [String.t()]}"
      )
    end

    nullable = Map.get(column, :nullable, true)

    unless is_boolean(nullable) do
      compile_error!(
        module,
        "column #{inspect(name)} declares a non-boolean :nullable (#{inspect(nullable)})"
      )
    end

    description = Map.get(column, :description)

    unless is_nil(description) or is_binary(description) do
      compile_error!(
        module,
        "column #{inspect(name)} declares a non-string :description (#{inspect(description)})"
      )
    end

    %{name: name, type: type, nullable: nullable, description: description}
  end

  defp validate_column!(module, other) do
    compile_error!(
      module,
      "each column must be a map with a string :name and a :type, got: #{inspect(other)}"
    )
  end

  @doc "Validate an `info/0` map. Raises `CompileError`; returns the normalized map."
  @spec validate_info!(module(), term()) :: info()
  def validate_info!(module, %{name: name} = info) when is_binary(name) and name != "" do
    primary_key = Map.get(info, :primary_key, [])

    unless is_list(primary_key) and Enum.all?(primary_key, &is_binary/1) do
      compile_error!(module, "info/0 :primary_key must be a list of column names")
    end

    %{
      name: name,
      title: Map.get(info, :title),
      description: Map.get(info, :description),
      primary_key: primary_key,
      writable: Map.get(info, :writable, module.__mcp_dataset__(:writable?))
    }
  end

  def validate_info!(module, other) do
    compile_error!(
      module,
      "info/0 must return a map with a non-empty string :name, got: #{inspect(other)}"
    )
  end

  @spec compile_error!(module(), String.t()) :: no_return()
  defp compile_error!(module, description) do
    raise CompileError,
      description: "#{inspect(module)} (Noizu.MCP.Server.Dataset): #{description}"
  end
end
