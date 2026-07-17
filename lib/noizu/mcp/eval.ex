defmodule Noizu.MCP.Eval do
  @moduledoc """
  Inline `@eval` annotations for description tuning (spec §4).

  Attach evals to a tool to continuously grade the *rendered* descriptions it
  advertises across model × verbosity permutations, so terser or model-specific
  variants (spec §2/§3) do not silently degrade call quality.

  ## Declaring evals

  On a classic `use Noizu.MCP.Server.Tool` module, pass the `:evals` option — a
  list of eval specs:

      use Noizu.MCP.Server.Tool,
        description: "...",
        evals: [
          [
            name: :simple_task,
            prompt: [%{role: "user", content: "Find recent docs about X."}],
            rubric: [
              covers_pitfall: "resulting call includes the required filters",
              fresh: "mentions post-cutoff knowledge-base entries"
            ]
          ]
        ]

  On a `use Noizu.MCP.Server.Toolkit` function, annotate with `@eval` (module
  attribute, `accumulate: true`) — each `@eval` drains onto the *following*
  `@mcp` tool, mirroring how `@mcp` itself is collected:

      @eval name: :simple_task, prompt: [...], rubric: [...]
      @mcp description: "...", input: [...]
      def read_file(args, ctx), do: ...

  Each eval spec is a keyword list:

    * `:name` (required) — an atom or non-empty string; unique per tool
    * `:prompt` (required) — a non-empty list of messages or a non-empty string
    * `:rubric` (required) — a non-empty keyword list of
      `criterion: "description"` (each description a string)

  Malformed specs are a compile error (`ArgumentError` from the classic tool DSL,
  `CompileError` from the toolkit DSL, matching each path's existing convention).

  ## Introspection

  `list/1` returns `[{tool_name, [%Noizu.MCP.Eval.Spec{}]}]` for every tool on a
  server module that carries evals — the entry point for the harness and any
  app-layer tooling.

  ## Harness

  `mix noizu.mcp.eval` (delegating to `Noizu.MCP.Eval.Harness`) renders each
  tool's wire schema through the §0/§2/§3 resolution pipeline for every selected
  permutation, runs the eval prompt against a target via a pluggable
  `Noizu.MCP.Eval.Runner`, and grades each rubric criterion via a pluggable
  `Noizu.MCP.Eval.Judge`. Adapters are selected via the `:noizu_mcp`
  `:eval_runner` / `:eval_judge` application env; a deterministic no-LLM stub
  pair ships for tests/CI. See those modules for the callback contracts.
  """

  alias Noizu.MCP.Eval.Spec
  alias Noizu.MCP.Server.Features

  @doc """
  List the evals declared on a server module.

  Returns `[{tool_name, [%Noizu.MCP.Eval.Spec{}]}]` for every registered tool
  that carries at least one eval; tools without evals are omitted. Order follows
  the server's tool registration order.

  Works against servers whose tool registry comes from the `tool` DSL macro (it
  reads `server.__mcp__(:tools)`); hand-written `handle_list_tools/2` servers
  report an empty list.
  """
  @spec list(module()) :: [{String.t(), [Spec.t()]}]
  def list(server) when is_atom(server) do
    server.__mcp__(:tools)
    |> Features.Tools.expand()
    |> Enum.map(fn spec -> {spec.definition.name, spec.evals || []} end)
    |> Enum.reject(fn {_name, evals} -> evals == [] end)
  end

  @doc """
  Compile and validate a list of raw eval specs into `[%Noizu.MCP.Eval.Spec{}]`.

  `context` names the owning tool for error messages. Raises `ArgumentError` on
  any malformed spec, missing required key, non-string rubric description, or
  duplicate eval name / rubric criterion. `nil` compiles to `[]`.
  """
  @spec compile_specs(nil | list(), String.t()) :: [Spec.t()]
  def compile_specs(nil, _context), do: []

  def compile_specs(specs, context) when is_list(specs) do
    compiled = Enum.map(specs, &compile_spec(&1, context))

    names = Enum.map(compiled, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        compiled

      dups ->
        raise ArgumentError,
              "#{context}: duplicate eval name(s): " <>
                Enum.map_join(Enum.uniq(dups), ", ", &inspect/1)
    end
  end

  def compile_specs(other, context) do
    raise ArgumentError,
          "#{context}: `evals:` must be a list of eval specs (keyword lists), got: " <>
            inspect(other)
  end

  # ── per-spec compilation ────────────────────────────────────────────────────

  defp compile_spec(raw, context) when is_list(raw) do
    unless Keyword.keyword?(raw), do: bad_eval!(context, raw)

    name = normalize_name!(Keyword.get(raw, :name), context)
    ctx = "#{context} eval #{inspect(name)}"

    unless Keyword.has_key?(raw, :prompt) do
      raise ArgumentError,
            "#{ctx}: `prompt:` is required (a non-empty list of messages or a string)"
    end

    %Spec{
      name: name,
      prompt: validate_prompt!(Keyword.get(raw, :prompt), ctx),
      rubric: validate_rubric!(raw, ctx)
    }
  end

  defp compile_spec(other, context), do: bad_eval!(context, other)

  defp bad_eval!(context, value) do
    raise ArgumentError,
          "#{context}: each eval must be a keyword list of [name:, prompt:, rubric:], got: " <>
            inspect(value)
  end

  defp normalize_name!(nil, context) do
    raise ArgumentError, "#{context}: eval `name:` is required (an atom or non-empty string)"
  end

  defp normalize_name!(name, context) when is_boolean(name) do
    raise ArgumentError,
          "#{context}: eval `name:` must be an atom or non-empty string, got: #{inspect(name)}"
  end

  defp normalize_name!(name, _context) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name!(name, _context) when is_binary(name) and name != "", do: name

  defp normalize_name!(other, context) do
    raise ArgumentError,
          "#{context}: eval `name:` must be an atom or non-empty string, got: #{inspect(other)}"
  end

  defp validate_prompt!(prompt, _context) when is_binary(prompt) and prompt != "", do: prompt
  defp validate_prompt!(prompt, _context) when is_list(prompt) and prompt != [], do: prompt

  defp validate_prompt!(prompt, context) do
    raise ArgumentError,
          "#{context}: `prompt:` must be a non-empty list of messages or a non-empty string, " <>
            "got: #{inspect(prompt)}"
  end

  defp validate_rubric!(raw, context) do
    unless Keyword.has_key?(raw, :rubric) do
      raise ArgumentError,
            "#{context}: `rubric:` is required (a non-empty keyword list of `criterion: \"description\"`)"
    end

    rubric = Keyword.get(raw, :rubric)

    unless is_list(rubric) and Keyword.keyword?(rubric) and rubric != [] do
      raise ArgumentError,
            "#{context}: `rubric:` must be a non-empty keyword list of " <>
              "`criterion: \"description\"`, got: #{inspect(rubric)}"
    end

    Enum.each(rubric, fn {criterion, description} ->
      unless is_binary(description) do
        raise ArgumentError,
              "#{context}: rubric criterion #{inspect(criterion)} description must be a string, " <>
                "got: #{inspect(description)}"
      end
    end)

    case Keyword.keys(rubric) |> then(&(&1 -- Enum.uniq(&1))) do
      [] ->
        rubric

      dups ->
        raise ArgumentError,
              "#{context}: duplicate rubric criterion #{inspect(Enum.uniq(dups))}"
    end
  end
end
