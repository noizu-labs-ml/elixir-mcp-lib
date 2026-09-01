defmodule Noizu.MCP.ACL.Resource do
  @moduledoc """
  The object of an authorization decision (PRD-2): what kind of surface is
  being gated and which one.

  `kind` is `:tool` | `:toolset` | `:prompt` | `:resource` | any host atom;
  `id` is the provider-facing identifier — for `kind: :tool`, the canonical
  wire name. The series scope (PRD-2) only exercises `kind: :tool`; the other
  kinds exist for the PRD-4 Store and host extension.
  """

  @enforce_keys [:kind, :id]
  defstruct [:kind, :id]

  @type kind :: :tool | :toolset | :prompt | :resource | atom()
  @type t :: %__MODULE__{kind: kind(), id: term()}
end
