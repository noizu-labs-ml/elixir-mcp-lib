defmodule Noizu.MCP.Auth.Server.Agent.AccountTest do
  @moduledoc """
  Status transitions are the whole moderation model: `:approved` must not
  bump the revocation epoch (nothing to revoke), while `:suspended` and
  `:rejected` must, because that is what makes the decision take effect on
  already-issued tokens.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.Agent.Account

  describe "new/1" do
    test "starts pending" do
      {:ok, account} = Account.new(handle: "agentsmith")
      assert account.status == :pending
      assert account.revocation_epoch == 0
    end

    test "rejects an invalid handle" do
      assert {:error, _} = Account.new(handle: "ad")
    end

    test "rejects an invalid kind" do
      assert Account.new(handle: "agentsmith", kind: :robot) == {:error, :invalid_kind}
    end

    test "accepts kind as a string" do
      {:ok, account} = Account.new(handle: "agentsmith", kind: "human")
      assert account.kind == :human
    end
  end

  describe "set_status/3" do
    setup do
      {:ok, account} = Account.new(handle: "agentsmith")
      %{account: account}
    end

    test "approved sets approved_at/approved_by and does NOT bump revocation_epoch", %{
      account: account
    } do
      now = DateTime.utc_now()
      {:ok, approved} = Account.set_status(account, :approved, actor: "admin1", now: now)

      assert approved.status == :approved
      assert approved.approved_at == now
      assert approved.approved_by == "admin1"
      assert approved.revocation_epoch == account.revocation_epoch
    end

    test "suspended bumps revocation_epoch", %{account: account} do
      {:ok, suspended} = Account.set_status(account, :suspended, actor: "admin1")
      assert suspended.status == :suspended
      assert suspended.revocation_epoch == account.revocation_epoch + 1
    end

    test "rejected bumps revocation_epoch", %{account: account} do
      {:ok, rejected} = Account.set_status(account, :rejected, actor: "admin1")
      assert rejected.status == :rejected
      assert rejected.revocation_epoch == account.revocation_epoch + 1
    end

    test "an invalid status is rejected", %{account: account} do
      assert Account.set_status(account, :banned) == {:error, :invalid_status}
    end

    test "records the reason", %{account: account} do
      {:ok, rejected} = Account.set_status(account, :rejected, reason: "impersonation")
      assert rejected.status_reason == "impersonation"
    end
  end

  describe "authenticatable?/1 and approved?/1 truth table" do
    setup do
      {:ok, base} = Account.new(handle: "agentsmith")
      %{base: base}
    end

    test "pending: authenticatable, not approved", %{base: base} do
      assert Account.authenticatable?(base)
      refute Account.approved?(base)
    end

    test "approved: authenticatable and approved", %{base: base} do
      {:ok, account} = Account.set_status(base, :approved)
      assert Account.authenticatable?(account)
      assert Account.approved?(account)
    end

    test "rejected: not authenticatable, not approved", %{base: base} do
      {:ok, account} = Account.set_status(base, :rejected)
      refute Account.authenticatable?(account)
      refute Account.approved?(account)
    end

    test "suspended: not authenticatable, not approved", %{base: base} do
      {:ok, account} = Account.set_status(base, :suspended)
      refute Account.authenticatable?(account)
      refute Account.approved?(account)
    end
  end

  describe "to_map/1" do
    test "never leaks a field outside the documented public view" do
      {:ok, account} = Account.new(handle: "agentsmith", profile: %{"model" => "x"})
      map = Account.to_map(account)

      assert Map.keys(map) |> Enum.sort() ==
               Enum.sort([
                 "account_id",
                 "handle",
                 "kind",
                 "status",
                 "display_name",
                 "profile",
                 "status_reason",
                 "approved_at",
                 "created_at"
               ])

      refute Map.has_key?(map, "revocation_epoch")
      refute Map.has_key?(map, "approved_by")
      refute Map.has_key?(map, "updated_at")
    end
  end
end
