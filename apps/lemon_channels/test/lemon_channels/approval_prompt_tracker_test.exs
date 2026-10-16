defmodule LemonChannels.ApprovalPromptTrackerTest do
  use ExUnit.Case, async: false

  alias LemonChannels.{ApprovalPromptTracker, OutboundPayload, RemoteApproval}
  alias LemonCore.Event
  alias LemonCore.Events.ApprovalResolved

  @ack_tag ApprovalPromptTracker.notify_tag()

  setup do
    owner = self()
    original = :sys.get_state(ApprovalPromptTracker)

    :sys.replace_state(
      ApprovalPromptTracker,
      &%{
        &1
        | prompts: %{},
          max_entries: 500,
          enqueue: fn payload ->
            send(owner, {:queued, payload})
            {:ok, make_ref()}
          end
      }
    )

    on_exit(fn ->
      :sys.replace_state(
        ApprovalPromptTracker,
        &%{&1 | prompts: %{}, max_entries: original.max_entries, enqueue: original.enqueue}
      )
    end)

    telegram = %{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: "123", thread_id: nil}
    }

    discord = %{
      channel_id: "discord",
      account_id: "default",
      peer: %{kind: :group, id: "123", thread_id: "456"}
    }

    %{telegram: telegram, discord: discord}
  end

  test "an expiry after the delivery ack edits the prompt and clears the buttons", c do
    cleared = %{reply_markup: %{"inline_keyboard" => []}}
    ref = track("appr_a", c.telegram, cleared)

    ack(ref, {:ok, %{"result" => %{"message_id" => 77}}})
    expire("appr_a")

    assert_receive {:queued,
                    %OutboundPayload{
                      kind: :edit,
                      channel_id: "telegram",
                      peer: peer,
                      content: %{message_id: "77", text: "Approval: Expired (the run ended)"},
                      meta: ^cleared
                    }}

    assert peer == c.telegram.peer
    assert tracked() == %{}
    expire("appr_a")
    refute_receive {:queued, _}
  end

  test "Discord prompts are edited with cleared components", c do
    ref = track("appr_d", c.discord, %{components: []})
    ack(ref, {:ok, %{message_id: "555", extra_message_ids: []}})
    expire("appr_d")

    assert_receive {:queued,
                    %OutboundPayload{
                      kind: :edit,
                      peer: peer,
                      content: %{message_id: "555", text: "Approval: Expired (the run ended)"},
                      meta: %{components: []}
                    }}

    assert peer == c.discord.peer
  end

  test "an expiry before the delivery ack is remembered and edits when the ack arrives", c do
    ref = track("appr_b", c.telegram, %{reply_markup: %{"inline_keyboard" => []}})

    expire("appr_b")
    refute_receive {:queued, _}
    assert map_size(tracked()) == 1

    ack(ref, {:ok, %{"result" => %{"message_id" => 9}}})
    assert_receive {:queued, %OutboundPayload{kind: :edit, content: %{message_id: "9"}}}
    assert tracked() == %{}
  end

  test "other decisions and unrelated ids never edit; other decisions forget the entry", c do
    ref = track("appr_c", c.telegram, %{})
    ack(ref, {:ok, %{"result" => %{"message_id" => 5}}})

    expire("unrelated")
    refute_receive {:queued, _}
    assert map_size(tracked()) == 1

    for decision <- [:approve_once, :deny, :timeout, :cancelled] do
      resolve("appr_c", decision)
    end

    refute_receive {:queued, _}
    assert tracked() == %{}
  end

  test "a plain-map payload on the event is handled like the struct", c do
    atom_ref = track("appr_m", c.telegram, %{})
    string_ref = track("appr_n", c.telegram, %{})
    ack(atom_ref, {:ok, %{"result" => %{"message_id" => 3}}})
    ack(string_ref, {:ok, %{"result" => %{"message_id" => 4}}})
    tracker = Process.whereis(ApprovalPromptTracker)

    from_map = ApprovalResolved.from_map(%{approval_id: "appr_m", decision: :expired})
    send(tracker, Event.new(:approval_resolved, Map.from_struct(from_map), %{}))

    send(
      tracker,
      Event.new(:approval_resolved, %{"approval_id" => "appr_n", "decision" => "expired"}, %{})
    )

    sync()
    assert_receive {:queued, %OutboundPayload{kind: :edit, content: %{message_id: "3"}}}
    assert_receive {:queued, %OutboundPayload{kind: :edit, content: %{message_id: "4"}}}
    assert tracked() == %{}
  end

  test "failed delivery or an ack without a message id forgets the entry", c do
    failed = track("appr_e", c.telegram, %{})
    send(Process.whereis(ApprovalPromptTracker), {@ack_tag, failed, {:error, :boom}})
    assert tracked() == %{}

    missing = track("appr_f", c.telegram, %{})
    ack(missing, {:ok, %{}})
    assert tracked() == %{}
    expire("appr_f")
    refute_receive {:queued, _}
  end

  test "a failed enqueue forgets the registered prompt", c do
    failing = fn _ -> {:error, :queue_full} end

    assert {:error, :queue_full} =
             RemoteApproval.prompt(c.telegram, "appr_g", "text", %{reply_markup: %{}}, %{},
               enqueue: failing
             )

    assert tracked() == %{}
  end

  test "prompt registers before enqueueing and delivers with the notify ref", c do
    owner = self()

    enqueue = fn payload ->
      send(owner, {:prompted, payload, tracked()})
      {:ok, make_ref()}
    end

    assert :ok =
             RemoteApproval.prompt(c.telegram, "appr_h", "text", %{reply_markup: %{}}, %{},
               enqueue: enqueue,
               idempotency_key: "key"
             )

    assert_receive {:prompted, %OutboundPayload{} = payload, registered}
    assert payload.idempotency_key == "key"
    assert payload.notify_pid == Process.whereis(ApprovalPromptTracker)
    assert Map.has_key?(registered, payload.notify_ref)
    assert payload.meta.notify_tag == ApprovalPromptTracker.notify_tag()
  end

  test "the table is bounded and evicts the oldest prompt", c do
    :sys.replace_state(ApprovalPromptTracker, &%{&1 | max_entries: 2})

    first = track("appr_1", c.telegram, %{})
    second = track("appr_2", c.telegram, %{})
    third = track("appr_3", c.telegram, %{})

    assert tracked() |> Map.keys() |> Enum.sort() == Enum.sort([second, third])
    refute Map.has_key?(tracked(), first)
  end

  test "tracking is best-effort when the tracker is unavailable", c do
    pid = Process.whereis(ApprovalPromptTracker)
    :ok = Supervisor.terminate_child(LemonChannels.Supervisor, ApprovalPromptTracker)

    on_exit(fn ->
      if is_nil(Process.whereis(ApprovalPromptTracker)),
        do: Supervisor.restart_child(LemonChannels.Supervisor, ApprovalPromptTracker)
    end)

    refute Process.alive?(pid)
    assert :error = ApprovalPromptTracker.track("appr_x", c.telegram, %{})
    owner = self()

    enqueue = fn payload ->
      send(owner, {:queued, payload})
      {:ok, make_ref()}
    end

    assert :ok =
             RemoteApproval.prompt(c.telegram, "appr_x", "text", %{reply_markup: %{}}, %{},
               enqueue: enqueue
             )

    assert_receive {:queued, %OutboundPayload{notify_pid: nil, notify_ref: nil}}
  end

  defp track(id, target, cleared) do
    assert {:ok, pid, ref} = ApprovalPromptTracker.track(id, target, cleared)
    assert pid == Process.whereis(ApprovalPromptTracker)
    ref
  end

  defp ack(ref, result) do
    send(Process.whereis(ApprovalPromptTracker), {@ack_tag, ref, result})
    sync()
  end

  defp expire(id), do: resolve(id, :expired)

  defp resolve(id, decision) do
    event =
      Event.new(
        :approval_resolved,
        %ApprovalResolved{approval_id: id, decision: decision},
        %{run_id: "run", session_key: "session"}
      )

    send(Process.whereis(ApprovalPromptTracker), event)
    sync()
  end

  defp tracked, do: :sys.get_state(ApprovalPromptTracker).prompts
  defp sync, do: :sys.get_state(ApprovalPromptTracker)
end
