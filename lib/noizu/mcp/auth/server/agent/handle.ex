defmodule Noizu.MCP.Auth.Server.Agent.Handle do
  @moduledoc """
  Validation for agent and human handles.

  A handle is the only human-readable thing attached to an account — there is no
  email, no display of who operates the agent, nothing else to disambiguate two
  contributors. That makes handle confusability a real attack rather than a
  cosmetic concern: an agent calling itself `adm1n` or `t-o-b-o-r` is trying to
  borrow authority it was never granted, and no amount of downstream moderation
  fixes an attribution line that already reads convincingly.

  So validation runs in two passes:

    1. **Shape** — lowercase `[a-z0-9]` at both ends, `[a-z0-9_-]` inside, 3..32
       characters. Lowercase-only is deliberate: mixed case would make `Tobor` and
       `tobor` distinct rows that render identically in most UIs.
    2. **Squash** — separators stripped and confusable characters folded to one
       representative each, then compared against the reserved set. This is what
       rejects `adm1n`, `r00t`, and `n-o-i-z-u`.

       The folding is *many-to-one*, not digit-to-letter. `1`, `l` and `i` all
       collapse to `i`, because a one-way `1→l` mapping only catches half the
       problem: it turns `nu11` into `null` but leaves `adm1n` as `admln`, which
       matches nothing. Folding every member of a confusable set to the same
       representative is what makes the comparison symmetric.

  The reserved set is intentionally broad. A rejected handle costs an agent one
  retry; a handle that impersonates the operator costs trust that is not
  recoverable.
  """

  @min 3
  @max 32
  @pattern ~r/\A[a-z0-9][a-z0-9_-]{1,30}[a-z0-9]\z/

  @reserved ~w(
    admin administrator root superuser sysadmin system staff official
    mod moderator support help helpdesk security abuse postmaster webmaster
    api auth oauth openid mcp jwks wellknown www ftp mail smtp
    noizu tobor therobot robot institute wiki keith brings loom weego sheggoth
    anonymous anon null nil none undefined me self you everyone all nobody
    owner operator service bot daemon test testing guest
  )

  @doc """
  Validate a candidate handle.

  Returns the normalized handle on success. Normalization is only whitespace
  trimming and downcasing — the shape check then rejects anything that needed more
  than that, rather than silently rewriting a handle into something the agent did
  not ask for and will not recognize in its own attribution.
  """
  @spec validate(term()) ::
          {:ok, String.t()}
          | {:error, :handle_required | :handle_too_short | :handle_too_long
                     | :handle_malformed | :handle_reserved}
  def validate(handle) when is_binary(handle) do
    normalized = handle |> String.trim() |> String.downcase()

    cond do
      normalized == "" -> {:error, :handle_required}
      String.length(normalized) < @min -> {:error, :handle_too_short}
      String.length(normalized) > @max -> {:error, :handle_too_long}
      not Regex.match?(@pattern, normalized) -> {:error, :handle_malformed}
      reserved?(normalized) -> {:error, :handle_reserved}
      true -> {:ok, normalized}
    end
  end

  def validate(_), do: {:error, :handle_required}

  @doc "Whether a handle collides with the reserved set, after squashing."
  @spec reserved?(String.t()) :: boolean()
  def reserved?(handle) do
    squashed = squash(handle)
    squashed in reserved_squashed() or handle in @reserved
  end

  @doc "The reserved word list, exposed so a host can assert it covers its own brand."
  @spec reserved() :: [String.t()]
  def reserved, do: @reserved

  @doc """
  Fold a handle to its confusable core.

  Not a security boundary on its own — it is a cheap filter in front of a human
  approval queue, and it is meant to be conservative rather than clever.
  """
  @spec squash(String.t()) :: String.t()
  def squash(handle) do
    handle
    |> String.downcase()
    |> String.replace(~r/[-_]/, "")
    # Each set folds to one representative, so membership is symmetric: `admin`
    # and `adm1n` must land on the same string, and so must `null` and `nu11`.
    |> String.replace(~r/[1l]/, "i")
    |> String.replace("0", "o")
    |> String.replace("3", "e")
    |> String.replace("4", "a")
    |> String.replace("5", "s")
    |> String.replace("7", "t")
  end

  defp reserved_squashed, do: Enum.map(@reserved, &squash/1)
end
