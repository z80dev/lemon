defmodule LemonGateway.Sms.InboxTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Sms.Inbox

  @table :sms_inbox

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    # Ensure a deterministic inbox number for default matching.
    prev = System.get_env("TWILIO_INBOX_NUMBER")
    System.put_env("TWILIO_INBOX_NUMBER", "+15551239999")

    # Clean slate for this table (new feature; no other tests should depend on it).
    for {k, _v} <- LemonCore.Store.list(@table) do
      _ = LemonCore.Store.delete(@table, k)
    end

    on_exit(fn ->
      if is_nil(prev) do
        System.delete_env("TWILIO_INBOX_NUMBER")
      else
        System.put_env("TWILIO_INBOX_NUMBER", prev)
      end

      for {k, _v} <- LemonCore.Store.list(@table) do
        _ = LemonCore.Store.delete(@table, k)
      end
    end)

    :ok
  end

  test "ingest_twilio_sms dedupes by MessageSid" do
    sid = "SM#{System.unique_integer([:positive])}"

    params = %{
      "MessageSid" => sid,
      "From" => "+15551230000",
      "To" => "+15551239999",
      "Body" => "Your code is 123456"
    }

    assert {:ok, :stored} = Inbox.ingest_twilio_sms(params)
    assert {:ok, :duplicate} = Inbox.ingest_twilio_sms(params)

    msgs = Inbox.list_messages(limit: 10, include_claimed: true)
    assert length(msgs) == 1
    assert hd(msgs)["message_sid"] == sid
  end

  test "wait_for_code returns an existing matching message and claims it by default" do
    sid = "SM#{System.unique_integer([:positive])}"

    params = %{
      "MessageSid" => sid,
      "From" => "+15551230001",
      "To" => "+15551239999",
      "Body" => "Verification: 7777"
    }

    assert {:ok, :stored} = Inbox.ingest_twilio_sms(params)

    assert {:ok, %{code: "7777", message: msg}} =
             Inbox.wait_for_code("session-a", timeout_ms: 2_000)

    assert msg["message_sid"] == sid
    assert msg["claimed_by"] == "session-a"

    # Claimed messages are hidden by default from list_messages/1
    assert Inbox.list_messages(limit: 10) == []

    msgs = Inbox.list_messages(limit: 10, include_claimed: true)
    assert length(msgs) == 1
    assert hd(msgs)["claimed_by"] == "session-a"
  end

  test "wait_for_code can block until a message arrives" do
    sid = "SM#{System.unique_integer([:positive])}"

    t =
      Task.async(fn ->
        Inbox.wait_for_code("session-b", timeout_ms: 5_000)
      end)

    # Give the waiter a moment to register
    Process.sleep(50)

    params = %{
      "MessageSid" => sid,
      "From" => "+15551230002",
      "To" => "+15551239999",
      "Body" => "Code: 888888"
    }

    assert {:ok, :stored} = Inbox.ingest_twilio_sms(params)

    assert {:ok, %{code: "888888", message: msg}} = Task.await(t, 5_000)
    assert msg["message_sid"] == sid
    assert msg["claimed_by"] == "session-b"
  end

  test "claim_message prevents claiming by another session" do
    sid = "SM#{System.unique_integer([:positive])}"

    params = %{
      "MessageSid" => sid,
      "From" => "+15551230003",
      "To" => "+15551239999",
      "Body" => "Hello 4321"
    }

    assert {:ok, :stored} = Inbox.ingest_twilio_sms(params)

    assert :ok = Inbox.claim_message("session-x", sid)
    assert {:error, :already_claimed} = Inbox.claim_message("session-y", sid)
    assert :ok = Inbox.claim_message("session-x", sid)
  end

  test "list_messages filters by to/from_contains/body_contains and include_claimed" do
    sid1 = "SM#{System.unique_integer([:positive])}"
    sid2 = "SM#{System.unique_integer([:positive])}"

    assert {:ok, :stored} =
             Inbox.ingest_twilio_sms(%{
               "MessageSid" => sid1,
               "From" => "+15551230010",
               "To" => "+15551239999",
               "Body" => "Acme code 111111"
             })

    assert {:ok, :stored} =
             Inbox.ingest_twilio_sms(%{
               "MessageSid" => sid2,
               "From" => "+15551230011",
               "To" => "+15551239999",
               "Body" => "Beta code 222222"
             })

    assert :ok = Inbox.claim_message("session-z", sid2)

    # default: claimed excluded
    msgs = Inbox.list_messages(limit: 10)
    assert length(msgs) == 1
    assert hd(msgs)["message_sid"] == sid1

    # include claimed
    msgs = Inbox.list_messages(limit: 10, include_claimed: true)
    assert Enum.map(msgs, & &1["message_sid"]) |> Enum.sort() == Enum.sort([sid1, sid2])

    # from_contains is case-insensitive
    msgs = Inbox.list_messages(limit: 10, include_claimed: true, from_contains: "0010")
    assert length(msgs) == 1
    assert hd(msgs)["message_sid"] == sid1

    msgs = Inbox.list_messages(limit: 10, include_claimed: true, body_contains: "Beta")
    assert length(msgs) == 1
    assert hd(msgs)["message_sid"] == sid2

    msgs = Inbox.list_messages(limit: 10, include_claimed: true, to: "+15551239999")
    assert length(msgs) == 2
  end
end

