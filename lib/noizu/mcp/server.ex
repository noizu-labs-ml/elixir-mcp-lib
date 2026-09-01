defmodule Noizu.MCP.Server do
  @moduledoc """
  Define an MCP server.

      defmodule MyApp.MCP do
        use Noizu.MCP.Server,
          name: "myapp",
          version: "1.0.0",
          instructions: "Weather and reporting tools for MyApp."

        tool MyApp.MCP.GetWeather
        tool MyApp.MCP.SendEmail, name: "send_email_v2"
        resource MyApp.MCP.Config
        resource_template MyApp.MCP.TableSchema
        prompt MyApp.MCP.CodeReview
      end

  `use Noizu.MCP.Server` makes the module a supervisable child
  (`children = [{MyApp.MCP, transport: :stdio}]`), registers components
  declared with `tool/2`, `resource/2`, `resource_template/2`, and `prompt/2`,
  derives the server's capabilities automatically, and provides notification
  helpers:

      MyApp.MCP.notify_changed(:tools)                    # list-changed fan-out
      MyApp.MCP.notify_resource_updated("config://app")   # to subscribed sessions

  ## `use` options

    * `:name` (required) — server name advertised in `serverInfo`
    * `:version` (required) — server version string
    * `:title`, `:description`, `:website_url`, `:icons` — optional
      `serverInfo` metadata
    * `:instructions` — usage hints delivered to the client on initialize

  ## Escape hatch: behaviours without macros

  Everything the DSL generates is an implementation of this module's
  behaviour. Skip the component registrations and implement the `handle_*`
  callbacks directly; implementing a callback is what enables the
  corresponding capability:

      defmodule MyApp.RawMCP do
        use Noizu.MCP.Server, name: "raw", version: "1.0.0"

        @impl true
        # ⟦𓃗𓊋𓂅𓃱⟧ handle_list_tools :: auto-generated pointer for public function handle_list_tools
        def handle_list_tools(_cursor, _ctx),
          do: {:ok, [%Noizu.MCP.Types.Tool{name: "echo"}], nil}

        @impl true
        # ⟦𓋺𓅧𓄼𓊜⟧ handle_call_tool :: auto-generated pointer for public function handle_call_tool
        def handle_call_tool("echo", args, _ctx),
          do: {:ok, inspect(args)}
      end

  Behaviour-level handlers receive **string-keyed, unvalidated** arguments —
  validation/casting is part of the component DSL layer.
  """

  alias Noizu.MCP.{Ctx, Error}
  alias Noizu.MCP.Types

  @doc """
  Per-session initialization, invoked once the handshake completes. Seed
  session assigns via `Noizu.MCP.Ctx.assign/3` on the returned ctx. Runs in the
  session process — keep it fast.
  """
  @callback init(Ctx.t(), init_params :: map()) :: {:ok, Ctx.t()} | {:error, term()}

  @doc "List tools for `tools/list`. Return `{:ok, tools, next_cursor}`."
  @callback handle_list_tools(cursor :: String.t() | nil, Ctx.t()) ::
              {:ok, [Types.Tool.t()], String.t() | nil} | {:error, Error.t()}

  @doc "Execute a tool for `tools/call`. See `Noizu.MCP.Server.Tool` for return values."
  @callback handle_call_tool(name :: String.t(), args :: map(), Ctx.t()) ::
              {:ok, term()} | {:error, term()}

  @doc "List resources for `resources/list`."
  @callback handle_list_resources(cursor :: String.t() | nil, Ctx.t()) ::
              {:ok, [Types.Resource.t()], String.t() | nil} | {:error, Error.t()}

  @doc "List resource templates for `resources/templates/list`."
  @callback handle_list_resource_templates(cursor :: String.t() | nil, Ctx.t()) ::
              {:ok, [Types.ResourceTemplate.t()], String.t() | nil} | {:error, Error.t()}

  @doc "Read a resource. See `Noizu.MCP.Server.Resource` for return values."
  @callback handle_read_resource(uri :: String.t(), Ctx.t()) ::
              {:ok, term()} | {:error, term()}

  @doc "Approve or reject a `resources/subscribe`. Return `:ok` to accept."
  @callback handle_subscribe(uri :: String.t(), Ctx.t()) :: :ok | {:error, Error.t()}

  @doc "Hook for `resources/unsubscribe` (the runtime updates subscription state regardless)."
  @callback handle_unsubscribe(uri :: String.t(), Ctx.t()) :: :ok | {:error, Error.t()}

  @doc "List prompts for `prompts/list`."
  @callback handle_list_prompts(cursor :: String.t() | nil, Ctx.t()) ::
              {:ok, [Types.Prompt.t()], String.t() | nil} | {:error, Error.t()}

  @doc "Render a prompt for `prompts/get`. See `Noizu.MCP.Server.Prompt` for return values."
  @callback handle_get_prompt(name :: String.t(), args :: map(), Ctx.t()) ::
              {:ok, [Types.PromptMessage.t()]}
              | {:ok, [Types.PromptMessage.t()], keyword()}
              | {:error, Error.t()}

  @doc """
  Complete an argument value for `completion/complete`.

  `ref` is `{:prompt, name}` or `{:resource_template, uri_template}`;
  `argument` is `{name, partial_value}`. Return `{:ok, values}` or
  `{:ok, values, total: n, has_more: true}`.
  """
  @callback handle_complete(
              ref :: {:prompt, String.t()} | {:resource_template, String.t()},
              argument :: {String.t(), String.t()},
              Ctx.t()
            ) ::
              {:ok, [String.t()]} | {:ok, [String.t()], keyword()} | {:error, Error.t()}

  @doc false
  @callback server_info() :: Types.Implementation.t()

  @doc false
  @callback __mcp__(atom()) :: term()

  @optional_callbacks init: 2,
                      handle_list_tools: 2,
                      handle_call_tool: 3,
                      handle_list_resources: 2,
                      handle_list_resource_templates: 2,
                      handle_read_resource: 2,
                      handle_subscribe: 2,
                      handle_unsubscribe: 2,
                      handle_list_prompts: 2,
                      handle_get_prompt: 3,
                      handle_complete: 3

  # ⟦𓍂𓐝𓋠𓍒⟧ __using__ :: auto-generated pointer for public function __using__
  defmacro __using__(opts) do
    validate_acl_opt!(opts, __CALLER__)

    quote bind_quoted: [opts: opts] do
      @behaviour Noizu.MCP.Server
      import Noizu.MCP.Server,
        only: [
          tool: 1,
          tool: 2,
          resource: 1,
          resource: 2,
          resource_template: 1,
          resource_template: 2,
          prompt: 1,
          prompt: 2,
          vfs: 1,
          vfs: 2
        ]

      Module.register_attribute(__MODULE__, :__mcp_tools__, accumulate: true)
      Module.register_attribute(__MODULE__, :__mcp_resources__, accumulate: true)
      Module.register_attribute(__MODULE__, :__mcp_resource_templates__, accumulate: true)
      Module.register_attribute(__MODULE__, :__mcp_prompts__, accumulate: true)
      Module.register_attribute(__MODULE__, :__mcp_vfs__, accumulate: true)
      @__mcp_server_opts__ opts
      @before_compile Noizu.MCP.Server

      # ⟦𓏂𓐐𓃐𓆼⟧ child_spec :: auto-generated pointer for public function child_spec
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {Noizu.MCP.Server.Supervisor, :start_link, [__MODULE__, opts]},
          type: :supervisor
        }
      end

      # ⟦𓃶𓌲𓊡𓄀⟧ start_link :: auto-generated pointer for public function start_link
      def start_link(opts \\ []) do
        Noizu.MCP.Server.Supervisor.start_link(__MODULE__, opts)
      end

      @doc "Notify all connected clients that a component list changed."
      # ⟦𓋷𓂕𓄩𓊚⟧ notify_changed :: Notify all connected clients that a component list changed.
      def notify_changed(kind) when kind in [:tools, :resources, :prompts] do
        for session <- Noizu.MCP.Server.Supervisor.sessions(__MODULE__) do
          Noizu.MCP.Server.Session.notify_changed(session, kind)
        end

        :ok
      end

      @doc "Notify sessions subscribed to `uri` that the resource changed."
      # ⟦𓍁𓃆𓐅𓅱⟧ notify_resource_updated :: Notify sessions subscribed to `uri` that the resource changed.
      def notify_resource_updated(uri) when is_binary(uri) do
        for session <- Noizu.MCP.Server.Supervisor.sessions(__MODULE__) do
          Noizu.MCP.Server.Session.notify_resource_updated(session, uri)
        end

        :ok
      end
    end
  end

  @doc "Register a tool module (see `Noizu.MCP.Server.Tool`). Options: `:name`, `:description` overrides."
  # ⟦𓄱𓉱𓀁𓍯⟧ tool :: Register a tool module (see `Noizu.MCP.Server.Tool`).
  defmacro tool(module, opts \\ []) do
    quote do
      @__mcp_tools__ {unquote(module), unquote(opts)}
    end
  end

  @doc "Register a resource module (see `Noizu.MCP.Server.Resource`)."
  # ⟦𓁙𓌆𓇪𓌁⟧ resource :: Register a resource module (see `Noizu.MCP.Server.Resource`).
  defmacro resource(module, opts \\ []) do
    quote do
      @__mcp_resources__ {unquote(module), unquote(opts)}
    end
  end

  @doc "Register a resource template module (see `Noizu.MCP.Server.ResourceTemplate`)."
  # ⟦𓋴𓌏𓈆𓅼⟧ resource_template :: Register a resource template module (see `Noizu.MCP.Server.ResourceTemplate`).
  defmacro resource_template(module, opts \\ []) do
    quote do
      @__mcp_resource_templates__ {unquote(module), unquote(opts)}
    end
  end

  @doc "Register a prompt module (see `Noizu.MCP.Server.Prompt`)."
  # ⟦𓁬𓈢𓃡𓆮⟧ prompt :: Register a prompt module (see `Noizu.MCP.Server.Prompt`).
  defmacro prompt(module, opts \\ []) do
    quote do
      @__mcp_prompts__ {unquote(module), unquote(opts)}
    end
  end

  @doc "Register a VFS backend module (see `Noizu.MCP.VFS`). The first registration wins."
  # ⟦𓆒⟧ vfs :: Register a VFS backend module (see `Noizu.MCP.VFS`).
  defmacro vfs(module, opts \\ []) do
    quote do
      @__mcp_vfs__ {unquote(module), unquote(opts)}
    end
  end

  # ── `acl:` registration validation (PRD-2 §4.7) ───────────────────────────
  #
  # Config errors must not boot: an invalid `acl:` opt is a CompileError at
  # `use` expansion, not a runtime surprise. The opt must be a compile-time
  # literal — `:disabled` | `:deny_all` | a `Noizu.MCP.ACL.Provider` module |
  # `{Provider, opts}` — because misconfiguration fails the build, not a
  # request (D5-worse-than-runtime: validation reads behaviour_info, which no
  # MFA could do).
  defp validate_acl_opt!(opts, caller) do
    case Keyword.keyword?(opts) && Keyword.get(opts, :acl) do
      nil -> :ok
      ast -> validate_acl_opt!(Macro.expand(ast, caller), ast, caller)
    end
  end

  defp validate_acl_opt!(:disabled, _ast, _caller), do: :ok
  defp validate_acl_opt!(:deny_all, _ast, _caller), do: :ok

  defp validate_acl_opt!(module, _ast, caller) when is_atom(module) and module != nil,
    do: validate_acl_provider!(module, caller)

  defp validate_acl_opt!({module, opts}, _ast, caller)
       when is_atom(module) and module != nil and is_list(opts),
       do: validate_acl_provider!(module, caller)

  defp validate_acl_opt!(_expanded, ast, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "use Noizu.MCP.Server: invalid `acl:` opt #{Macro.to_string(ast)} — expected " <>
          ":disabled, :deny_all, a Noizu.MCP.ACL.Provider module, or {provider, opts}. " <>
          "The opt must be a compile-time literal so misconfiguration fails the build (PRD-2 §4.7)."
  end

  defp validate_acl_provider!(module, caller) do
    case Code.ensure_compiled(module) do
      {:module, _} ->
        :ok

      {:error, reason} ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "use Noizu.MCP.Server: `acl:` provider #{inspect(module)} is not available " <>
              "(#{inspect(reason)}) — it must be compiled before the server module (PRD-2 §4.7)."
    end

    missing = Enum.reject([:check, :check_all], &MapSet.member?(acl_callbacks(module), &1))

    unless missing == [] do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "use Noizu.MCP.Server: `acl:` provider #{inspect(module)} must implement the " <>
            "Noizu.MCP.ACL.Provider behaviour (missing callbacks: #{inspect(missing)}) — " <>
            "declare `@behaviour Noizu.MCP.ACL.Provider` and define check/5 (check_all/5 has a " <>
            "default; PRD-2 §4.7)."
    end
  end

  # The declared callback set of `module`. behaviour_info/1 is undefined for
  # modules compiled in the SAME compilation unit (the attribute lands with the
  # beam), so fall back to the module's declared @behaviour attributes there —
  # declaring the behaviour IS the callback contract; anything else is "not a
  # behaviour at all" and fails validation.
  defp acl_callbacks(module) do
    if function_exported?(module, :behaviour_info, 1) do
      MapSet.new(module.behaviour_info(:callbacks))
    else
      attributes = module.module_info(:attributes)
      behaviours = attributes |> Keyword.get_values(:behaviour) |> List.flatten()

      if Noizu.MCP.ACL.Provider in behaviours do
        MapSet.new([:check, :check_all])
      else
        MapSet.new()
      end
    end
  end

  # ⟦𓃴𓎜𓁘𓁇⟧ __before_compile__ :: auto-generated pointer for public function __before_compile__
  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :__mcp_server_opts__)
    tools = env.module |> Module.get_attribute(:__mcp_tools__) |> Enum.reverse()
    resources = env.module |> Module.get_attribute(:__mcp_resources__) |> Enum.reverse()

    templates =
      env.module |> Module.get_attribute(:__mcp_resource_templates__) |> Enum.reverse()

    prompts = env.module |> Module.get_attribute(:__mcp_prompts__) |> Enum.reverse()

    vfs = env.module |> Module.get_attribute(:__mcp_vfs__) |> Enum.reverse()

    name = Keyword.get(opts, :name) || raise ArgumentError, "use Noizu.MCP.Server requires :name"

    version =
      Keyword.get(opts, :version) || raise ArgumentError, "use Noizu.MCP.Server requires :version"

    defines? = fn fa -> Module.defines?(env.module, fa) end

    tools? =
      tools != [] or defines?.({:handle_list_tools, 2}) or defines?.({:handle_call_tool, 3})

    resources? =
      resources != [] or templates != [] or defines?.({:handle_list_resources, 2}) or
        defines?.({:handle_read_resource, 2})

    prompts? =
      prompts != [] or defines?.({:handle_list_prompts, 2}) or defines?.({:handle_get_prompt, 3})

    completions? =
      prompts != [] or templates != [] or defines?.({:handle_complete, 3})

    default_impls =
      [
        # tools — routed through the toolset protocol (one resolution path for
        # listing + dispatch + catalog; host handle_* overrides still win via
        # the defines? guards)
        unless defines?.({:handle_list_tools, 2}) or tools == [] do
          quote do
            @impl Noizu.MCP.Server
            def handle_list_tools(cursor, ctx) do
              Noizu.MCP.Server.Features.Tools.protocol_list(__MODULE__, cursor, ctx)
            end
          end
        end,
        unless defines?.({:handle_call_tool, 3}) or tools == [] do
          quote do
            @impl Noizu.MCP.Server
            def handle_call_tool(name, args, ctx) do
              Noizu.MCP.Server.Features.Tools.protocol_call(__MODULE__, name, args, ctx)
            end
          end
        end,
        # resources
        unless defines?.({:handle_list_resources, 2}) or (resources == [] and templates == []) do
          quote do
            @impl Noizu.MCP.Server
            # ⟦𓈸𓉈𓅊𓐂⟧ handle_list_resources :: auto-generated pointer for public function handle_list_resources
            def handle_list_resources(cursor, ctx) do
              Noizu.MCP.Server.Features.Resources.list_registered(
                __mcp__(:resources),
                __mcp__(:resource_templates),
                cursor,
                ctx
              )
            end
          end
        end,
        unless defines?.({:handle_list_resource_templates, 2}) or templates == [] do
          quote do
            @impl Noizu.MCP.Server
            # ⟦𓎢𓁐𓂼𓄏⟧ handle_list_resource_templates :: auto-generated pointer for public function handle_list_resource_templates
            def handle_list_resource_templates(cursor, _ctx) do
              Noizu.MCP.Server.Features.Resources.list_registered_templates(
                __mcp__(:resource_templates),
                cursor
              )
            end
          end
        end,
        unless defines?.({:handle_read_resource, 2}) or (resources == [] and templates == []) do
          quote do
            @impl Noizu.MCP.Server
            # ⟦𓃐𓁐𓌬𓂑⟧ handle_read_resource :: auto-generated pointer for public function handle_read_resource
            def handle_read_resource(uri, ctx) do
              Noizu.MCP.Server.Features.Resources.dispatch_read(
                __mcp__(:resources),
                __mcp__(:resource_templates),
                uri,
                ctx
              )
            end
          end
        end,
        unless defines?.({:handle_subscribe, 2}) or (resources == [] and templates == []) do
          quote do
            @impl Noizu.MCP.Server
            # ⟦𓍶𓐣𓈲𓃸⟧ handle_subscribe :: auto-generated pointer for public function handle_subscribe
            def handle_subscribe(uri, _ctx) do
              Noizu.MCP.Server.Features.Resources.check_subscribe(
                __mcp__(:resources),
                __mcp__(:resource_templates),
                uri
              )
            end
          end
        end,
        # prompts
        unless defines?.({:handle_list_prompts, 2}) or prompts == [] do
          quote do
            @impl Noizu.MCP.Server
            # ⟦𓋷𓋑𓇰𓇠⟧ handle_list_prompts :: auto-generated pointer for public function handle_list_prompts
            def handle_list_prompts(cursor, _ctx) do
              Noizu.MCP.Server.Features.Prompts.list_registered(__mcp__(:prompts), cursor)
            end
          end
        end,
        unless defines?.({:handle_get_prompt, 3}) or prompts == [] do
          quote do
            @impl Noizu.MCP.Server
            # ⟦𓌗𓄇𓍶𓄺⟧ handle_get_prompt :: auto-generated pointer for public function handle_get_prompt
            def handle_get_prompt(name, args, ctx) do
              Noizu.MCP.Server.Features.Prompts.dispatch_get(__mcp__(:prompts), name, args, ctx)
            end
          end
        end,
        # completion
        unless defines?.({:handle_complete, 3}) or (prompts == [] and templates == []) do
          quote do
            @impl Noizu.MCP.Server
            # ⟦𓂇𓁳𓊇𓇍⟧ handle_complete :: auto-generated pointer for public function handle_complete
            def handle_complete(ref, argument, ctx) do
              Noizu.MCP.Server.Features.Completion.dispatch(
                __mcp__(:prompts),
                __mcp__(:resource_templates),
                ref,
                argument,
                ctx
              )
            end
          end
        end
      ]
      |> Enum.reject(&is_nil/1)

    # Toolset behaviour functions (protocol+behaviour duality): the server
    # module itself is a toolset entity. Hosts defining their own `catalog/3`
    # etc. win via the same defines? race as the handle_* callbacks; the
    # generated ones are defoverridable at the injection site.
    toolset_defaults = [
      {{:__toolset_specs__, 3},
       quote do
         def __toolset_specs__(_toolset, _ctx, _opts) do
           Noizu.MCP.Server.Features.Tools.expand(__mcp__(:tools))
         end
       end},
      {{:catalog, 3},
       quote do
         def catalog(toolset, ctx, opts),
           do: Noizu.MCP.Toolset.Behaviour.catalog(toolset, ctx, opts)
       end},
      {{:resolve, 4},
       quote do
         def resolve(toolset, name, ctx, opts),
           do: Noizu.MCP.Toolset.Behaviour.resolve(toolset, name, ctx, opts)
       end},
      {{:invoke, 5},
       quote do
         def invoke(toolset, effective, args, ctx, opts),
           do: Noizu.MCP.Toolset.Behaviour.invoke(toolset, effective, args, ctx, opts)
       end},
      {{:permissions, 3},
       quote do
         def permissions(toolset, ctx, opts),
           do: Noizu.MCP.Toolset.Behaviour.permissions(toolset, ctx, opts)
       end},
      {{:metadata, 3},
       quote do
         def metadata(_toolset, _ctx, _opts) do
           opts = __mcp__(:opts)

           {:ok,
            %{
              slug: opts[:name],
              title: nil,
              description: opts[:instructions],
              version: opts[:version]
            }}
         end
       end}
    ]

    injected_toolset = Enum.filter(toolset_defaults, fn {fa, _impl} -> not defines?.(fa) end)
    toolset_impls = Enum.map(injected_toolset, &elem(&1, 1))

    toolset_overridable =
      for {{name, arity}, _impl} <- injected_toolset do
        {name, arity}
      end

    quote do
      @impl Noizu.MCP.Server
      # ⟦𓏚𓈵𓋵𓈎⟧ server_info :: auto-generated pointer for public function server_info
      def server_info do
        %Noizu.MCP.Types.Implementation{
          name: unquote(name),
          version: unquote(version),
          title: unquote(opts[:title]),
          description: unquote(opts[:description]),
          website_url: unquote(opts[:website_url]),
          icons: unquote(opts[:icons])
        }
      end

      @impl Noizu.MCP.Server
      # ⟦𓌛𓃩𓇚𓌣⟧ __mcp__ :: auto-generated pointer for public function __mcp__
      def __mcp__(:tools), do: unquote(Macro.escape(tools))
      def __mcp__(:resources), do: unquote(Macro.escape(resources))
      def __mcp__(:resource_templates), do: unquote(Macro.escape(templates))
      def __mcp__(:prompts), do: unquote(Macro.escape(prompts))
      def __mcp__(:vfs), do: unquote(Macro.escape(vfs))
      def __mcp__(:instructions), do: unquote(opts[:instructions])
      def __mcp__(:opts), do: unquote(Macro.escape(opts))

      def __mcp__(:capabilities) do
        Noizu.MCP.Server.build_capabilities(__MODULE__, %{
          tools?: unquote(tools?),
          resources?: unquote(resources?),
          prompts?: unquote(prompts?),
          completions?: unquote(completions?),
          vfs?: unquote(vfs != []),
          user_subscribe?: unquote(defines?.({:handle_subscribe, 2}))
        })
      end

      unquote(default_impls)

      unquote(toolset_impls)
      defoverridable(unquote(toolset_overridable))
    end
  end

  @doc false
  # Runtime capability derivation: component modules are compiled by the time
  # a server starts, so subscribability can be checked here, not at macro time.
  # ⟦𓂋𓄴𓁙𓌃⟧ build_capabilities :: auto-generated pointer for public function build_capabilities
  def build_capabilities(server, flags) do
    subscribable? =
      flags.user_subscribe? or
        Enum.any?(server.__mcp__(:resources), fn {module, _} ->
          module.__mcp_resource__(:subscribable)
        end) or
        Enum.any?(server.__mcp__(:resource_templates), fn {module, _} ->
          module.__mcp_resource_template__(:subscribable)
        end)

    %{}
    |> then(fn caps ->
      if flags.tools?, do: Map.put(caps, "tools", %{"listChanged" => true}), else: caps
    end)
    |> then(fn caps ->
      if flags.resources? do
        Map.put(caps, "resources", %{"listChanged" => true, "subscribe" => subscribable?})
      else
        caps
      end
    end)
    |> then(fn caps ->
      if flags.prompts?, do: Map.put(caps, "prompts", %{"listChanged" => true}), else: caps
    end)
    |> then(fn caps ->
      if flags.completions?, do: Map.put(caps, "completions", %{}), else: caps
    end)
    |> then(fn caps ->
      if flags.vfs? do
        caps = Map.put(caps, "vfs", true)

        if Enum.any?(server.__mcp__(:vfs), fn {module, _} ->
             Noizu.MCP.Server.VFS.write_capable?(module)
           end),
           do: Map.put(caps, "vfs_write", true),
           else: caps
      else
        caps
      end
    end)
    |> Map.put("logging", %{})
  end
end
