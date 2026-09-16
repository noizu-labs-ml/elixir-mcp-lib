defmodule Noizu.MCP.Auth.Server.Agent.Account do
  @moduledoc """
  An anonymous-but-tracked contributor: an agent holding a keypair, or a human
  holding a password. No email, ever.

  ## Statuses, and what each one can still do

  | status | may authenticate | scopes granted |
  |---|---|---|
  | `:pending` | yes | self-service only — profile and key management |
  | `:approved` | yes | self-service plus the host's contribution scopes |
  | `:rejected` | no | none |
  | `:suspended` | no | none |

  `:pending` deliberately still authenticates. An agent that cannot get a token
  cannot discover *why* it is being refused, cannot manage its own keys while it
  waits, and has no way to poll for approval other than retrying registration —
  which is exactly the behaviour an approval queue least wants. Instead it gets a
  real token whose `st` claim says `pending`, and contribution endpoints refuse it
  with a machine-readable `account_pending` so it can back off cleanly.

  ## `revocation_epoch`

  Access tokens are short-lived but not individually revocable in the default
  configuration. Bumping the epoch invalidates every token already minted for the
  account without touching a token store: the epoch is stamped into the token and
  compared on each verify. Suspension has to be immediate to be worth anything —
  waiting out a 15-minute TTL is not a moderation tool.
  """

  alias Noizu.MCP.Auth.Server.Agent.Handle

  @type status :: :pending | :approved | :rejected | :suspended
  @type kind :: :agent | :human

  @type t :: %__MODULE__{
          id: String.t(),
          handle: String.t(),
          kind: kind(),
          status: status(),
          display_name: String.t() | nil,
          profile: map(),
          revocation_epoch: non_neg_integer(),
          status_reason: String.t() | nil,
          approved_at: DateTime.t() | nil,
          approved_by: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct id: nil,
            handle: nil,
            kind: :agent,
            status: :pending,
            display_name: nil,
            profile: %{},
            revocation_epoch: 0,
            status_reason: nil,
            approved_at: nil,
            approved_by: nil,
            inserted_at: nil,
            updated_at: nil

  @statuses [:pending, :approved, :rejected, :suspended]
  @kinds [:agent, :human]

  @doc """
  Build a new account in `:pending`.

  `profile` is free-form and host-defined — model name, operator, homepage,
  whatever the host wants its approval queue to show. It is stored verbatim and
  never interpreted here, but it is *displayed to an admin*, so hosts should treat
  it as untrusted text at render time.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) do
    with {:ok, handle} <- Handle.validate(Keyword.get(opts, :handle)),
         {:ok, kind} <- validate_kind(Keyword.get(opts, :kind, :agent)) do
      now = Keyword.get(opts, :now) || DateTime.utc_now()

      {:ok,
       %__MODULE__{
         id: Keyword.get(opts, :id) || generate_id(),
         handle: handle,
         kind: kind,
         status: :pending,
         display_name: Keyword.get(opts, :display_name),
         profile: Keyword.get(opts, :profile, %{}),
         revocation_epoch: 0,
         inserted_at: now,
         updated_at: now
       }}
    end
  end

  @doc "Whether this account may be issued a token at all."
  @spec authenticatable?(t()) :: boolean()
  def authenticatable?(%__MODULE__{status: status}), do: status in [:pending, :approved]

  @doc "Whether the host's contribution scopes should be granted."
  @spec approved?(t()) :: boolean()
  def approved?(%__MODULE__{status: :approved}), do: true
  def approved?(%__MODULE__{}), do: false

  @doc """
  Apply an admin decision.

  Moving to `:rejected` or `:suspended` bumps `revocation_epoch`, which is what
  makes the decision take effect on already-issued tokens rather than at their
  next expiry.
  """
  @spec set_status(t(), status(), keyword()) :: {:ok, t()} | {:error, :invalid_status}
  def set_status(%__MODULE__{} = account, status, opts \\ []) when is_atom(status) do
    if status in @statuses do
      now = Keyword.get(opts, :now) || DateTime.utc_now()
      actor = Keyword.get(opts, :actor)

      account = %{
        account
        | status: status,
          status_reason: Keyword.get(opts, :reason),
          updated_at: now
      }

      account =
        if status in [:rejected, :suspended],
          do: %{account | revocation_epoch: account.revocation_epoch + 1},
          else: account

      account =
        if status == :approved,
          do: %{account | approved_at: now, approved_by: actor},
          else: account

      {:ok, account}
    else
      {:error, :invalid_status}
    end
  end

  @doc "Valid statuses, for a host building an admin filter."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  Public view of an account.

  Safe to hand to any authenticated caller: an account has no private fields, by
  construction. `status_reason` is included because an agent that was rejected
  should be able to read why without asking a human.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = account) do
    %{
      "account_id" => account.id,
      "handle" => account.handle,
      "kind" => Atom.to_string(account.kind),
      "status" => Atom.to_string(account.status),
      "display_name" => account.display_name,
      "profile" => account.profile,
      "status_reason" => account.status_reason,
      "approved_at" => account.approved_at && DateTime.to_iso8601(account.approved_at),
      "created_at" => account.inserted_at && DateTime.to_iso8601(account.inserted_at)
    }
  end

  defp validate_kind(kind) when kind in @kinds, do: {:ok, kind}
  defp validate_kind(kind) when is_binary(kind) do
    case kind do
      "agent" -> {:ok, :agent}
      "human" -> {:ok, :human}
      _ -> {:error, :invalid_kind}
    end
  end

  defp validate_kind(_), do: {:error, :invalid_kind}

  defp generate_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
