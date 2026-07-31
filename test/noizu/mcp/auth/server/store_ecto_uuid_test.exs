defmodule Noizu.MCP.Auth.Server.Store.EctoUuidTest do
  @moduledoc """
  The **entire** `Store` conformance battery, run a second time against
  `Store.Ecto` with `subject_type: :uuid` and real `uuid` subject columns.

  This module exists because of a specific defect and is the structural answer
  to it. `put_consent/2` bound `consent.subject` raw while all seven sibling
  call sites routed through `dump_subject/2`. Against a `uuid` column that
  raised `DBConnection.EncodeError` on the *mandatory* authorization path —
  `AuthorizePlug` → `Consent.record/5` → `put_consent`, and consent is
  unconditional for every `:registered` and `:cimd` client, which is everything
  Claude and Codex use. Every first authorization by every client died there.

  The text-only battery could not see it: a text bind against a text column is
  fine no matter whether it was coerced. One missed call site out of eight is
  proof the pattern is forgettable, so rather than trusting an audit to have
  caught every one, the whole battery now runs under uuid too. Any future write
  that forgets `dump_subject/2` fails here, in the library, instead of in a host
  application's authorize leg.

  DB-gated on `MCP_OAUTH_TEST_DATABASE_URL` like the text battery — and, like
  it, a run without that variable now fails the suite rather than skipping in
  silence (see `test/test_helper.exs`).
  """
  use ExUnit.Case, async: false

  @database_url System.get_env("MCP_OAUTH_TEST_DATABASE_URL")

  if @database_url do
    defmodule Repo do
      @moduledoc false
      use Ecto.Repo, otp_app: :noizu_mcp, adapter: Ecto.Adapters.Postgres
    end

    alias Noizu.MCP.Auth.Server.Store
    alias Noizu.MCP.Auth.Server.TestSchema

    # Real uuids, because these go into real uuid columns.
    @subject_a "6f9619ff-8b86-d011-b42d-00cf4fc964ff"
    @subject_b "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

    setup_all do
      start_supervised!({Repo, url: @database_url, pool_size: 25, log: false})

      # Cleanup on the way in, never from on_exit — the repo is already stopped
      # by the time an on_exit callback runs, and the raise is reported as a
      # setup_all failure that invalidates every test in the module.
      Ecto.Adapters.SQL.query!(Repo, TestSchema.drop_sql(), [])
      Enum.each(TestSchema.create_sql(:uuid), &Ecto.Adapters.SQL.query!(Repo, &1, []))

      :ok
    end

    setup do
      Ecto.Adapters.SQL.query!(Repo, TestSchema.truncate_sql(), [])

      %{
        adapter: Store.Ecto,
        store_opts: [repo: Repo, subject_type: :uuid, track_access_tokens: true],
        subject_a: @subject_a,
        subject_b: @subject_b
      }
    end

    use Noizu.MCP.Auth.Server.StoreConformanceCase
  end
end
