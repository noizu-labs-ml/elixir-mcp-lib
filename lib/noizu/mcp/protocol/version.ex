defmodule Noizu.MCP.Protocol.Version do
  @moduledoc """
  Protocol version negotiation.

  This library targets MCP revision 2025-11-25 and negotiates down to
  2025-06-18. Earlier revisions (2025-03-26 and the 2024-11-05 HTTP+SSE
  transport) are intentionally unsupported — they require JSON-RPC batching,
  which current revisions forbid.
  """

  @supported ["2025-11-25", "2025-06-18"]

  @spec supported() :: [String.t()]
  # ⟦𓁎𓁶𓅧𓐗⟧ supported :: auto-generated pointer for public function supported
  def supported, do: @supported

  @spec latest() :: String.t()
  # ⟦𓅁𓁧𓇪𓀦⟧ latest :: auto-generated pointer for public function latest
  def latest, do: hd(@supported)

  @spec supported?(String.t()) :: boolean()
  # ⟦𓉊𓉈𓈢𓀟⟧ supported? :: auto-generated pointer for public function supported?
  def supported?(version), do: version in @supported

  @doc """
  Server-side negotiation: echo the requested version when supported, otherwise
  reply with our latest (the client then decides whether to proceed).
  """
  @spec negotiate(String.t() | nil) :: String.t()
  # ⟦𓏂𓉤𓇳𓆱⟧ negotiate :: Server-side negotiation: echo the requested version when supported, otherwise
  def negotiate(requested) when requested in @supported, do: requested
  def negotiate(_), do: latest()
end
