defmodule LemonGateway.Voice.CallSessionTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Voice.CallSession

  setup do
    unless Process.whereis(LemonGateway.Voice.CallRegistry) do
      start_supervised!({Registry, keys: :unique, name: LemonGateway.Voice.CallRegistry})
    end

    supervisor = start_supervised!(Task.Supervisor)
    %{task_supervisor: supervisor}
  end

  test "child spec keeps call sessions temporary" do
    assert CallSession.child_spec(call_sid: "call-1").restart == :temporary
  end

  test "audio is forwarded and activity updated without changing synthesis", context do
    session = start_call(context)
    CallSession.register_deepgram_ws(session, self())
    CallSession.handle_audio(session, <<1, 2, 3, 4>>)

    assert_receive {:"$websockex_cast", {:send_audio, <<1, 2, 3, 4>>}}
    assert {:idle, data} = :sys.get_state(session)
    assert data.deepgram_ws_pid == self()
    assert DateTime.compare(data.last_activity_at, data.started_at) in [:eq, :gt]
  end

  test "LLM result is synthesized and recorded through supervised tasks", context do
    owner = self()

    session =
      start_call(context,
        llm_fun: fn history ->
          send(owner, {:llm_history, history})
          "generated answer"
        end
      )

    transcript(session, "hello")
    assert_receive {:llm_history, [%{role: "user", content: "hello"} | _]}
    assert_receive {:tts, "generated answer", task}
    assert {:synthesizing, %{task: %Task{pid: ^task}}} = :sys.get_state(session)
    send(task, {:release, <<0, 0>>})
    assert_receive {:send_audio, _audio}
    assert {:idle, data} = :sys.get_state(session)
    assert hd(data.conversation_history) == %{role: "assistant", content: "generated answer"}
  end

  test "hung TTS expires and the next queued speech succeeds", context do
    session = start_call(context, tts_timeout_ms: 500)
    CallSession.speak(session, "hung speech")
    assert_receive {:tts, "hung speech", hung_task}
    monitor = Process.monitor(hung_task)
    CallSession.speak(session, "next speech")

    assert_receive {:DOWN, ^monitor, :process, ^hung_task, reason}, 2_000
    assert reason in [:killed, :noproc]
    assert_receive {:tts, "next speech", next_task}, 2_000
    send(next_task, {:release, <<0, 0>>})
    assert_receive {:send_audio, _audio}
    assert {:idle, data} = :sys.get_state(session)
    refute Enum.any?(data.conversation_history, &(&1.content == "hung speech"))
    assert hd(data.conversation_history).content == "next speech"
  end

  test "hung LLM expires without preventing subsequent speech", context do
    owner = self()

    session =
      start_call(context,
        llm_timeout_ms: 500,
        llm_fun: fn _history ->
          send(owner, {:llm_started, self()})

          receive do
            :never -> "late answer"
          end
        end
      )

    transcript(session, "hello")
    assert_receive {:llm_started, task}
    monitor = Process.monitor(task)
    CallSession.speak(session, "still available")
    assert_receive {:DOWN, ^monitor, :process, ^task, reason}, 2_000
    assert reason in [:killed, :noproc]
    assert_receive {:tts, "still available", next_task}, 2_000
    send(next_task, {:release, <<0, 0>>})
    assert_receive {:send_audio, _audio}
    assert {:idle, _data} = :sys.get_state(session)
  end

  test "playback marks and stale results cannot finish an active task", context do
    session = start_call(context)
    CallSession.speak(session, "first")
    assert_receive {:tts, "first", task}
    CallSession.speak(session, "second")
    send(session, :speech_complete)
    send(session, {make_ref(), {:ok, <<0, 0>>}})
    send(session, {:DOWN, make_ref(), :process, self(), :normal})

    assert {:synthesizing, data} = :sys.get_state(session)
    assert data.task.pid == task
    assert :queue.to_list(data.jobs) == [{:speak, "second"}]
    send(task, {:release, <<0, 0>>})
    assert_receive {:send_audio, _audio}
    assert_receive {:tts, "second", next_task}
    send(next_task, {:release, <<0, 0>>})
    assert_receive {:send_audio, _audio}
    assert {:idle, _data} = :sys.get_state(session)
  end

  test "TTS failure advances the queue without needing a playback callback", context do
    session = start_call(context)
    CallSession.speak(session, "failed")
    assert_receive {:tts, "failed", task}
    CallSession.speak(session, "next")
    send(task, {:release_error, :provider_failed})
    assert_receive {:tts, "next", next_task}
    send(next_task, {:release, <<0, 0>>})
    assert_receive {:send_audio, _audio}
    assert {:idle, _data} = :sys.get_state(session)
  end

  test "task death does not crash the call or strand queued work", context do
    session = start_call(context)
    CallSession.speak(session, "crashed")
    assert_receive {:tts, "crashed", task}
    CallSession.speak(session, "next")
    Process.exit(task, :kill)
    assert_receive {:tts, "next", next_task}
    send(next_task, {:release, <<0, 0>>})
    assert_receive {:send_audio, _audio}
    assert {:idle, _data} = :sys.get_state(session)
  end

  test "ending a call terminates its supervised active task", context do
    session = start_call(context)
    CallSession.speak(session, "still running")
    assert_receive {:tts, "still running", task}
    task_monitor = Process.monitor(task)
    session_monitor = Process.monitor(session)
    CallSession.end_call(session)
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :killed}
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}
  end

  test "a killed call owner cannot orphan its provider task", context do
    session = start_call(context)
    CallSession.speak(session, "still running")
    assert_receive {:tts, "still running", task}
    monitor = Process.monitor(task)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
  end

  test "silence closes the call even after goodbye finishes and audio arrives", context do
    session = start_call(context, silence_timeout_ms: 1_000)
    monitor = Process.monitor(session)
    assert_receive {:tts, "Thanks for calling! Goodbye.", goodbye_task}, 2_000
    CallSession.handle_audio(session, <<0, 0>>)
    send(goodbye_task, {:release, <<0, 0>>})
    assert_receive {:send_audio, _audio}
    assert {:closing, %{task: nil}} = :sys.get_state(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 4_000
  end

  test "missing Twilio still advances synthesis", context do
    session = start_call(context)
    CallSession.register_twilio_ws(session, nil)
    CallSession.speak(session, "no websocket")
    assert_receive {:tts, "no websocket", task}
    CallSession.speak(session, "next")
    send(task, {:release, <<0, 0>>})
    assert_receive {:tts, "next", next_task}
    assert {:synthesizing, data} = :sys.get_state(session)
    assert data.task.pid == next_task
    assert hd(data.conversation_history).content == "no websocket"
  end

  describe "call-owned sockets" do
    setup do
      unless Process.whereis(LemonGateway.Voice.DeepgramSupervisor) do
        start_supervised!(
          {DynamicSupervisor,
           name: LemonGateway.Voice.DeepgramSupervisor, strategy: :one_for_one},
          id: :deepgram_sup
        )
      end

      :ok
    end

    test "gateway builds a temporary media stream and routes provider callbacks to the call" do
      spec = LemonGateway.Voice.DeepgramCall.child_spec(call_sid: "CA1", session_pid: self())

      assert %{
               restart: :temporary,
               start: {LemonMedia.Providers.DeepgramStream, :start_link, [opts]}
             } =
               spec

      assert opts[:name] == {:via, Registry, {LemonGateway.Voice.DeepgramRegistry, "CA1"}}
      opts[:on_connect].(self())
      assert_receive {:"$gen_cast", {:register_deepgram_ws, _pid}}

      result = %{"type" => "Results", "is_final" => false}
      opts[:on_transcript].(result)
      assert_receive {:"$gen_cast", {:transcript, ^result}}
    end

    test "self-terminating session closes its Deepgram socket and the Twilio stream", context do
      session = start_call(context, silence_timeout_ms: 1_000)
      deepgram = start_fake_deepgram()
      deepgram_ref = Process.monitor(deepgram)
      CallSession.register_deepgram_ws(session, deepgram)
      session_ref = Process.monitor(session)

      # Silence path: goodbye, then the session stops itself.
      assert_receive {:tts, "Thanks for calling! Goodbye.", goodbye}, 2_000
      send(goodbye, {:release, <<0, 0>>})
      assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 4_000
      assert_receive {:DOWN, ^deepgram_ref, :process, ^deepgram, _}, 1_000
      assert_receive :call_ended
    end

    test "a killed session takes its Deepgram socket down", context do
      session = start_call(context)
      deepgram = start_fake_deepgram()
      deepgram_ref = Process.monitor(deepgram)
      CallSession.register_deepgram_ws(session, deepgram)
      _ = :sys.get_state(session)
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^deepgram_ref, :process, ^deepgram, _}, 1_000
    end
  end

  defp start_fake_deepgram do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        LemonGateway.Voice.DeepgramSupervisor,
        %{
          id: :fake,
          start: {Agent, :start_link, [fn -> :ok end]},
          restart: :temporary
        }
      )

    pid
  end

  defp start_call(context, opts \\ []) do
    owner = self()

    defaults = [
      call_sid: "statem-call-#{System.unique_integer([:positive])}",
      task_supervisor: context.task_supervisor,
      silence_timeout_ms: :infinity,
      llm_timeout_ms: :infinity,
      tts_timeout_ms: :infinity,
      tts_fun: fn text ->
        send(owner, {:tts, text, self()})

        receive do
          {:release, audio} -> {:ok, audio}
          {:release_error, reason} -> {:error, reason}
        end
      end
    ]

    session = start_supervised!({CallSession, Keyword.merge(defaults, opts)})
    assert_receive {:tts, _welcome, task}
    CallSession.register_twilio_ws(session, self())
    assert {:synthesizing, _data} = :sys.get_state(session)
    send(task, {:release, <<0, 0>>})
    assert_receive {:send_audio, _audio}
    assert {:idle, _data} = :sys.get_state(session)
    session
  end

  defp transcript(session, text) do
    CallSession.handle_transcript(session, %{
      "is_final" => true,
      "channel" => %{"alternatives" => [%{"transcript" => text}]}
    })
  end
end
