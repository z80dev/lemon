defmodule CodingAgent.Tools.Task.ChildInboxTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Task.ChildInbox

  setup do
    {inbox, monitor} = ChildInbox.start()
    %{inbox: inbox, monitor: monitor}
  end

  test "admitted content stays in the child mailbox, not an owner queue", %{inbox: inbox} do
    for n <- 1..64 do
      assert :ok = ChildInbox.deliver(inbox, "message #{n}", self())
    end

    assert {:messages, messages} = Process.info(inbox, :messages)
    assert messages == Enum.map(1..64, &{:task_message, "message #{&1}"})

    assert {:error, "Task message queue is full (64 messages / 256 KiB)"} =
             ChildInbox.deliver(inbox, "overflow", self())

    assert {:deliver_pending, deliveries} = ChildInbox.attach(inbox, self(), self())
    assert length(deliveries) == 64

    for n <- 1..64 do
      text = "message #{n}"
      assert_receive {:"$gen_cast", {:steer, ^text, false, _, _}}
    end

    assert :ok = ChildInbox.detach(inbox)
    assert :ok = ChildInbox.deliver(inbox, "fresh capacity", self())
    assert {:messages, [{:task_message, "fresh capacity"}]} = Process.info(inbox, :messages)
  end

  test "the byte cap includes envelopes and is enforced at admission", %{inbox: inbox} do
    envelope = String.duplicate("x", 32 * 1024 + 100)
    for _ <- 1..7, do: assert(:ok = ChildInbox.deliver(inbox, envelope, self()))
    assert {:error, _} = ChildInbox.capacity(inbox, envelope)
    assert {:error, _} = ChildInbox.deliver(inbox, envelope, self())

    assert :ok = ChildInbox.detach(inbox)
    assert :ok = ChildInbox.deliver(inbox, String.duplicate("x", 256 * 1024), self())
    assert {:error, _} = ChildInbox.deliver(inbox, "x", self())
  end

  test "only the owning coordinator can admit or consume child messages", %{inbox: inbox} do
    outsider = Task.async(fn -> ChildInbox.deliver(inbox, "not authorized", self()) end)
    assert {:error, "Task inbox owner mismatch"} = Task.await(outsider)
    assert :ok = ChildInbox.deliver(inbox, "owned", self())
    assert {:messages, [{:task_message, "owned"}]} = Process.info(inbox, :messages)
  end

  test "stopping an inbox discards its pending content", %{inbox: inbox, monitor: monitor} do
    assert :ok = ChildInbox.deliver(inbox, "discard", self())
    assert :ok = ChildInbox.stop(inbox)
    assert_receive {:DOWN, ^monitor, :process, ^inbox, :normal}
    assert {:error, "Task inbox is unavailable"} = ChildInbox.deliver(inbox, "late", self())
    refute_received {:"$gen_cast", {:steer, _, _, _, _}}
  end

  test "inbox lifetime is bounded by its coordinator monitor" do
    test = self()

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        {inbox, _monitor} = ChildInbox.start()
        :ok = ChildInbox.deliver(inbox, "pending", self())
        send(test, {:inbox, inbox})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:inbox, inbox}
    inbox_monitor = Process.monitor(inbox)
    send(owner, :finish)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    assert_receive {:DOWN, ^inbox_monitor, :process, ^inbox, :normal}
  end
end
