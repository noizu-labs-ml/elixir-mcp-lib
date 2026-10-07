defmodule Noizu.MCP.Types.PromptMessage do
  @moduledoc """
  A message in a `prompts/get` result.

      PromptMessage.user("Review this code:")
      PromptMessage.assistant(Content.text("Sure —"))
  """

  alias Noizu.MCP.Types.Content

  @type t :: %__MODULE__{role: :user | :assistant, content: Content.t()}

  @enforce_keys [:role, :content]
  defstruct [:role, :content]

  @spec user(Content.t() | String.t()) :: t()
  # <REMOVED UUID HERE> user :: auto-generated pointer for public function user
  def user(content), do: %__MODULE__{role: :user, content: to_content(content)}

  @spec assistant(Content.t() | String.t()) :: t()
  # <REMOVED UUID HERE> assistant :: auto-generated pointer for public function assistant
  def assistant(content), do: %__MODULE__{role: :assistant, content: to_content(content)}

  defp to_content(%Content{} = content), do: content
  defp to_content(text) when is_binary(text), do: Content.text(text)

  @spec to_map(t()) :: map()
  # <REMOVED UUID HERE> to_map :: auto-generated pointer for public function to_map
  def to_map(%__MODULE__{} = message) do
    %{"role" => Atom.to_string(message.role), "content" => Content.to_map(message.content)}
  end

  @spec from_map(map()) :: t()
  # <REMOVED UUID HERE> from_map :: auto-generated pointer for public function from_map
  def from_map(%{"role" => role, "content" => content}) when role in ["user", "assistant"] do
    %__MODULE__{role: String.to_existing_atom(role), content: Content.from_map(content)}
  end
end
