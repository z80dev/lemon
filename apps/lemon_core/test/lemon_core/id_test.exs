defmodule LemonCore.IdTest do
  use ExUnit.Case, async: true

  alias LemonCore.Id

  doctest LemonCore.Id

  describe "uuid/0" do
    test "generates valid UUID v4" do
      uuid = Id.uuid()
      assert is_binary(uuid)
      assert String.length(uuid) == 36
      assert String.match?(uuid, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i)
    end

    test "generates unique UUIDs" do
      uuids = for _ <- 1..100, do: Id.uuid()
      assert length(Enum.uniq(uuids)) == 100
    end
  end

  describe "run_id/0" do
    test "generates run ID with prefix" do
      id = Id.run_id()
      assert String.starts_with?(id, "run_")
      assert String.length(id) == 40  # "run_" + 36 char UUID
    end
  end

  describe "session_id/0" do
    test "generates session ID with prefix" do
      id = Id.session_id()
      assert String.starts_with?(id, "sess_")
      assert String.length(id) == 41  # "sess_" + 36 char UUID
    end
  end

  describe "approval_id/0" do
    test "generates approval ID with prefix" do
      id = Id.approval_id()
      assert String.starts_with?(id, "appr_")
    end
  end

  describe "cron_id/0" do
    test "generates cron ID with prefix" do
      id = Id.cron_id()
      assert String.starts_with?(id, "cron_")
    end
  end

  describe "skill_id/0" do
    test "generates skill ID with prefix" do
      id = Id.skill_id()
      assert String.starts_with?(id, "skill_")
    end
  end

  describe "idempotency_key/2" do
    test "generates idempotency key with scope and operation" do
      key = Id.idempotency_key("messages", "send")
      assert String.starts_with?(key, "messages:send:")
    end
  end
end
