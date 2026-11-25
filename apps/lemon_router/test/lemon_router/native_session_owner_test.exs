defmodule LemonRouter.NativeSessionOwnerTest do
  @moduledoc """
  A native session belongs to the chat that created it. Another chat that
  shares the same agent, policy and workspace must not be able to resume it by
  id, and a run it completes must not make the creator's checkpoints reachable
  from that chat.
  """

  use ExUnit.Case, async: false

  alias LemonChannels.CheckpointStatusMessage
  alias LemonCore.{Event, ResumeToken, RunStore, SessionKey}
  alias LemonAgent.Checkpoint
  alias LemonRouter.RunProcess.CompactionTrigger
  alias LemonRouter.SubmissionBuilder

  setup do
    original_profiles_state = :sys.get_state(LemonRouter.AgentProfiles)

    :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
      %{
        state
        | profiles: %{
            "test" => %{
              id: "test",
              name: "Test Agent",
              tool_policy: nil,
              system_prompt: nil,
              model: nil
            }
          }
      }
    end)

    on_exit(fn ->
      :sys.replace_state(LemonRouter.AgentProfiles, fn _ -> original_profiles_state end)
    end)

    :ok
  end

  @tag :tmp_dir
  test "foreign resume, then completion, then checkpoint access are all refused",
       %{tmp_dir: tmp_dir} do
    victim_chat = "-100#{System.unique_integer([:positive])}"
    attacker_chat = "-200#{System.unique_integer([:positive])}"
    victim_key = group_key(victim_chat)
    attacker_key = group_key(attacker_chat)
    native = %ResumeToken{engine: "lemon", value: "native-victim-#{unique()}"}
    path = Path.join(tmp_dir, "victim.txt")
    File.write!(path, "victim-before\n")

    on_exit(fn ->
      Checkpoint.delete_all(native.value)

      for key <- [victim_key, attacker_key] do
        LemonCore.ChatStateStore.delete(key)
        LemonCore.RunHistoryStore.delete_session(key)
      end
    end)

    # The victim chat creates the native session and a checkpoint in it.
    assert {:ok, victim} = build(victim_key, victim_chat)
    complete(victim, native)
    assert {:ok, checkpoint} = Checkpoint.create_filesystem(native.value, [path], cwd: tmp_dir)
    File.write!(path, "victim-after\n")

    # The victim's own chat still resumes and reaches its checkpoint.
    assert {:ok, again} = build(victim_key, victim_chat)
    assert again.execution_request.resume == native
    assert CheckpointStatusMessage.owner_for_session_key(victim_key) == native.value

    # Another ordinary chat names the victim's native session explicitly.
    assert {:ok, foreign} = build(attacker_key, attacker_chat, resume: native)
    assert foreign.execution_request.resume == nil

    # Its run completes with whatever session the engine actually used.
    used =
      foreign.execution_request.resume ||
        %ResumeToken{engine: "lemon", value: "native-attacker-#{unique()}"}

    complete(foreign, used)

    owner = CheckpointStatusMessage.owner_for_session_key(attacker_key)
    refute owner == native.value

    opts = [session_key: attacker_key, sender_id: "666", checkpoint_owner: owner]
    preview = CheckpointStatusMessage.handle("restore #{checkpoint.id}", opts)
    assert preview =~ "not found in this chat's session"
    refute preview =~ "Confirm with"

    for token <- tokens_in(preview) do
      restored = CheckpointStatusMessage.handle("restore #{checkpoint.id} #{token}", opts)
      refute restored =~ "Checkpoint Restored"
    end

    assert CheckpointStatusMessage.handle("diff #{checkpoint.id}", opts) =~
             "not found in this chat's session"

    assert File.read!(path) == "victim-after\n"
  end

  test "a channel chat cannot resume or claim an unbound native session" do
    chat = "-500#{System.unique_integer([:positive])}"
    key = group_key(chat)
    legacy = %ResumeToken{engine: "lemon", value: "native-legacy-#{unique()}"}

    on_exit(fn ->
      LemonCore.ChatStateStore.delete(key)
      LemonCore.RunHistoryStore.delete_session(key)
    end)

    # Explicitly, and through chat state that `/resume` lets a user write.
    assert {:ok, explicit} = build(key, chat, resume: legacy)
    assert explicit.execution_request.resume == nil

    assert :ok =
             LemonCore.ChatStateStore.put(key, %{
               last_engine: "lemon",
               last_resume_token: legacy.value
             })

    assert {:ok, auto} = build(key, chat)
    assert auto.execution_request.resume == nil
  end

  test "router history naming another chat's native session grants no checkpoint owner" do
    victim_chat = "-300#{System.unique_integer([:positive])}"
    attacker_chat = "-400#{System.unique_integer([:positive])}"
    victim_key = group_key(victim_chat)
    attacker_key = group_key(attacker_chat)
    native = %ResumeToken{engine: "lemon", value: "native-history-#{unique()}"}

    on_exit(fn ->
      for key <- [victim_key, attacker_key] do
        LemonCore.ChatStateStore.delete(key)
        LemonCore.RunHistoryStore.delete_session(key)
      end
    end)

    assert {:ok, victim} = build(victim_key, victim_chat)
    complete(victim, native)

    # A history row for the attacker chat that carries the victim's session
    # (as a resumed run recorded before admission was owner-bound would).
    finalize_history(attacker_key, native)

    assert CheckpointStatusMessage.owner_for_session_key(victim_key) == native.value
    assert CheckpointStatusMessage.owner_for_session_key(attacker_key) == nil
  end

  defp build(session_key, chat_id, attrs \\ []) do
    meta = %{
      channel_context: %{
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :group,
        peer_id: chat_id,
        thread_id: nil
      },
      channel_identity: %{
        channel_id: "telegram",
        sender_id: "1",
        is_bot: false,
        owner?: false,
        verified?: true
      }
    }

    attrs
    |> Map.new()
    |> Map.merge(%{
      origin: :channel,
      agent_id: "test",
      session_key: session_key,
      prompt: "Hello",
      meta: meta,
      run_id: "run_#{unique()}"
    })
    |> LemonCore.RunRequest.new()
    |> SubmissionBuilder.build(%{
      run_supervisor: LemonRouter.RunSupervisor,
      run_process_module: LemonRouter.RunProcess,
      run_process_opts: %{notify_pid: self()}
    })
  end

  # The router's completion path: persist resume state, then the run summary.
  defp complete(submission, %ResumeToken{} = used) do
    request = submission.execution_request

    state = %{
      session_key: submission.session_key,
      run_id: request.run_id,
      execution_request: request
    }

    event = %Event{
      type: :run_completed,
      ts_ms: System.system_time(:millisecond),
      payload: %{completed: %{__event__: :completed, ok: true, resume: used}}
    }

    assert :ok = CompactionTrigger.maybe_store_chat_state(state, event)
    finalize_history(submission.session_key, used, request.run_id)
  end

  defp finalize_history(session_key, resume, run_id \\ "run_#{unique()}") do
    assert :ok =
             RunStore.finalize(run_id, %{
               session_key: session_key,
               completed: %{ok: true, resume: resume}
             })

    wait_until(fn ->
      session_key
      |> RunStore.history(limit: 5)
      |> Enum.any?(fn {id, _data} -> id == run_id end)
    end)
  end

  defp tokens_in(text) do
    Regex.scan(~r/restore chk_[0-9a-f]{16} (\S+)/, text) |> Enum.map(&List.last/1)
  end

  defp group_key(chat_id) do
    SessionKey.channel_peer(%{
      agent_id: "test",
      channel_id: "telegram",
      account_id: "default",
      peer_kind: :group,
      peer_id: chat_id
    })
  end

  defp unique, do: System.unique_integer([:positive, :monotonic])

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition was not met")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
