defmodule PhilosopherChatTest.StubDecider do
  @moduledoc false
  @behaviour LemonSim.Kernel.Decider

  @impl true
  def decide(_context, tools, _opts) do
    PhilosopherChatTest.DeciderHelpers.speak(tools)
  end
end

defmodule PhilosopherChatTest.BlockingStubDecider do
  @moduledoc false
  @behaviour LemonSim.Kernel.Decider

  @impl true
  def decide(_context, tools, _opts) do
    receive do
      :go -> PhilosopherChatTest.DeciderHelpers.speak(tools)
    end
  end
end

defmodule PhilosopherChatTest.KillingStubDecider do
  @moduledoc false
  @behaviour LemonSim.Kernel.Decider

  @impl true
  def decide(_context, _tools, _opts) do
    Process.exit(self(), :kill)
  end
end

defmodule PhilosopherChatTest.DeciderHelpers do
  @moduledoc false

  def speak(tools) do
    case Enum.find(tools, &(&1.name == "speak")) do
      nil ->
        {:error, :no_speak_tool}

      tool ->
        case tool.execute.(
               "stub",
               %{
                 "message" =>
                   "The unexamined life is not worth living, and I say this as one who examined it to the end."
               },
               nil,
               fn _update -> :ok end
             ) do
          {:ok, result} -> {:ok, %{"type" => "tool_call", "result_details" => result.details}}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end

defmodule LemonSimUi.PhilosopherChatTest do
  use ExUnit.Case, async: false

  alias LemonSim.Examples.PhilosopherChat, as: Domain
  alias LemonSim.Examples.PhilosopherChat.Pacing
  alias LemonSimUi.PhilosopherChat

  setup do
    keys = [
      :philosopher_chat_enabled,
      :philosopher_chat_ai_opts,
      :philosopher_chat_ai_model,
      :philosopher_chat_modules,
      :philosopher_chat_data_root,
      :philosopher_chat_thread_limit
    ]

    previous = Enum.map(keys, fn key -> {key, Application.get_env(:lemon_sim_ui, key)} end)

    Application.put_env(:lemon_sim_ui, :philosopher_chat_enabled, true)
    # Key present with a nil model so build_default_opts skips configured-model
    # resolution; the stub deciders ignore the model entirely.
    Application.put_env(:lemon_sim_ui, :philosopher_chat_ai_opts, model: nil, stream_options: %{})

    tmp =
      Path.join(System.tmp_dir!(), "philosopher_chat_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:lemon_sim_ui, :philosopher_chat_data_root, tmp)

    modules = %{Domain.modules() | decider: PhilosopherChatTest.StubDecider}
    Application.put_env(:lemon_sim_ui, :philosopher_chat_modules, modules)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:lemon_sim_ui, key),
          else: Application.put_env(:lemon_sim_ui, key, value)
      end)

      File.rm_rf(tmp)
    end)

    :ok
  end

  defp cleanup_threads do
    {:ok, threads} = PhilosopherChat.list_threads()

    Enum.each(threads, fn thread ->
      PhilosopherChat.delete_thread(thread.id)
    end)
  end

  defp thread_server_pid(thread_id) do
    [{pid, _}] = Registry.lookup(LemonSimUi.PhilosopherChat.Registry, thread_id)
    pid
  end

  # Drives the armed pending turn immediately instead of waiting out the
  # pacing delay: reuses the live turn_timer ref so the stale-ref guard
  # accepts the message.
  defp drive_pending_turn(thread_id) do
    pid = thread_server_pid(thread_id)
    server_state = :sys.get_state(pid)
    %{ref: ref} = server_state.turn_timer
    %{actor_id: actor_id} = server_state.thread.pending_turn
    send(pid, {:agent_turn, actor_id, ref})
    pid
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: raise("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  describe "coordinator" do
    test "creates a thread with validation" do
      assert {:ok, thread_id} =
               PhilosopherChat.create_thread("The Symposium", ["socrates", "nietzsche"])

      thread = PhilosopherChat.get_thread(thread_id)
      assert thread.name == "The Symposium"
      assert thread.member_ids == ["you", "socrates", "nietzsche"]
      assert thread.pace == "relaxed"
      assert thread.status == "active"
      assert thread.game_state.world.status == "active"

      assert {:ok, %{status: "active", id: ^thread_id}} = PhilosopherChat.view(thread_id)
      cleanup_threads()
    end

    test "rejects invalid members and names" do
      assert {:error, :name_required} = PhilosopherChat.create_thread("  ", ["socrates"])
      assert {:error, :too_few_members} = PhilosopherChat.create_thread("Solo", [])
      assert {:error, :unknown_member} = PhilosopherChat.create_thread("Bad", ["zeus"])

      assert {:error, :duplicate_member} =
               PhilosopherChat.create_thread("Bad", ["socrates", "socrates"])
    end

    test "lists threads sorted by recency" do
      {:ok, id1} = PhilosopherChat.create_thread("First", ["socrates"])
      {:ok, id2} = PhilosopherChat.create_thread("Second", ["nietzsche"])

      {:ok, threads} = PhilosopherChat.list_threads()
      assert length(threads) == 2
      assert Enum.any?(threads, &(&1.id == id1 and &1.name == "First"))
      assert Enum.any?(threads, &(&1.id == id2))

      first = Enum.find(threads, &(&1.id == id1))
      assert first.member_ids == ["you", "socrates"]
      assert first.message_count == 0
      cleanup_threads()
    end

    test "deletes threads" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Doomed", ["camus"])
      assert :ok = PhilosopherChat.delete_thread(thread_id)
      assert PhilosopherChat.get_thread(thread_id) == nil
    end
  end

  describe "thread server" do
    test "user message is committed, persisted, and schedules an agent turn" do
      {:ok, thread_id} = PhilosopherChat.create_thread("The Trial", ["kafka", "wittgenstein"])

      assert {:ok, view} = PhilosopherChat.post_user_message(thread_id, "What is the door for?")
      assert [%{author: "you", text: "What is the door for?"}] = view.messages

      thread = PhilosopherChat.get_thread(thread_id)
      assert length(thread.game_state.world.messages) == 1
      assert %{actor_id: agent_id} = thread.pending_turn
      assert agent_id in ["kafka", "wittgenstein"]

      cleanup_threads()
    end

    test "pause and resume control status" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Silence", ["kierkegaard"])
      assert {:ok, %{status: "paused"}} = PhilosopherChat.set_status(thread_id, "paused")
      assert {:error, :thread_not_active} = PhilosopherChat.post_user_message(thread_id, "hello?")
      assert {:ok, %{status: "active"}} = PhilosopherChat.set_status(thread_id, "active")
      cleanup_threads()
    end

    test "nudge schedules a specific agent" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Nudge", ["hume", "kant"])
      assert {:ok, %{scheduled: "kant"}} = PhilosopherChat.nudge(thread_id, "kant")

      thread = PhilosopherChat.get_thread(thread_id)
      assert %{actor_id: "kant"} = thread.pending_turn
      cleanup_threads()
    end

    test "agent turn posts a message through the stub decider pipeline" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Pipeline", ["socrates"])

      LemonCore.Bus.subscribe(PhilosopherChat.topic(thread_id))

      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "Socrates, what is justice?")

      # Drive the scheduled turn deterministically (the real timer would take
      # 25-90s; the server logic after the timer is identical).
      drive_pending_turn(thread_id)

      # The stub decider speaks, the updater commits, and the server
      # broadcasts the message on the thread topic.
      assert_receive %LemonCore.Event{
                       type: :philosopher_chat_update,
                       payload: %{type: "message", message: %{author: "socrates"}}
                     },
                     2_000

      # Wait for the async commit to settle, then verify the world state.
      Process.sleep(200)
      {:ok, view} = PhilosopherChat.view(thread_id)
      socrates_msg = Enum.find(view.messages, &(&1.author == "socrates"))
      assert socrates_msg != nil
      assert String.contains?(socrates_msg.text, "unexamined")

      # Typing state is cleared.
      assert view.typing == nil

      cleanup_threads()
    end

    test "threads survive ThreadServer restart" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Persist", ["weil"])
      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "What is attention?")

      # Kill the server; ensure_thread should restart it from the store.
      [{pid, _}] = Registry.lookup(LemonSimUi.PhilosopherChat.Registry, thread_id)
      Process.exit(pid, :kill)
      Process.sleep(100)

      assert {:ok, view} = PhilosopherChat.view(thread_id)
      assert length(view.messages) == 1
      assert view.name == "Persist"

      cleanup_threads()
    end

    test "memories endpoint reads the agent memory directory" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Mem", ["marx"])

      # Write a memory file the way an agent would (through the action space
      # memory tools, scoped to this thread + agent).
      thread = PhilosopherChat.get_thread(thread_id)
      state = Domain.with_actor(thread.game_state, "marx")

      {:ok, tools} =
        Domain.ActionSpace.tools(state,
          memory_root: PhilosopherChat.memory_root(),
          memory_namespace: PhilosopherChat.memory_namespace(thread_id)
        )

      writer = Enum.find(tools, &(&1.name == "memory_write_file"))

      assert {:ok, _} =
               writer.execute.(
                 "id",
                 %{"path" => "opinions/hegel.md", "content" => "Hegel stands on his head."},
                 nil,
                 fn _ -> :ok end
               )

      assert {:ok, %{files: files}} = PhilosopherChat.memories(thread_id, "marx")
      assert Enum.any?(files, &(&1.path == "index.md"))
      hegel = Enum.find(files, &(&1.path == "opinions/hegel.md"))
      assert hegel != nil
      assert String.contains?(hegel.content, "Hegel stands on his head")

      cleanup_threads()
    end
  end

  describe "turn lifecycle" do
    test "user message posted during an agent turn survives the commit (P0-1)" do
      Application.put_env(:lemon_sim_ui, :philosopher_chat_modules, %{
        Domain.modules()
        | decider: PhilosopherChatTest.BlockingStubDecider
      })

      {:ok, thread_id} = PhilosopherChat.create_thread("Race", ["socrates"])
      LemonCore.Bus.subscribe(PhilosopherChat.topic(thread_id))

      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "first")
      drive_pending_turn(thread_id)

      # The AI task is now blocked inside the decider. Post a second user
      # message while the model "runs".
      wait_until(fn ->
        Task.Supervisor.children(LemonSimUi.PhilosopherChat.AiTaskSupervisor) != []
      end)

      [task_pid] = Task.Supervisor.children(LemonSimUi.PhilosopherChat.AiTaskSupervisor)

      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "second")
      send(task_pid, :go)

      assert_receive %LemonCore.Event{
                       type: :philosopher_chat_update,
                       payload: %{type: "message", message: %{author: "socrates"}}
                     },
                     2_000

      Process.sleep(200)

      {:ok, view} = PhilosopherChat.view(thread_id)
      assert Enum.map(view.messages, & &1.author) == ["you", "you", "socrates"]
      assert Enum.map(view.messages, & &1.seq) == [1, 2, 3]
      assert Enum.map(view.messages, & &1.text) |> Enum.take(2) == ["first", "second"]

      cleanup_threads()
    end

    test "chained reply is scheduled after an agent speaks (P0-3)" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Chain", ["socrates", "nietzsche"])
      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "Socrates, what is justice?")

      # Force the continue-chatter roll to hit so the chain deterministically
      # continues after the agent speaks.
      pid = thread_server_pid(thread_id)

      :sys.replace_state(pid, fn server_state -> %{server_state | rng: hitting_chatter_seed()} end)

      drive_pending_turn(thread_id)

      # Wait for the agent message commit, then for the chained follow-up.
      wait_until(fn ->
        {:ok, view} = PhilosopherChat.view(thread_id)
        Enum.any?(view.messages, &(&1.author != "you"))
      end)

      wait_until(fn -> PhilosopherChat.get_thread(thread_id).pending_turn != nil end)
      assert %{actor_id: actor_id} = PhilosopherChat.get_thread(thread_id).pending_turn
      assert actor_id in ["socrates", "nietzsche"]

      cleanup_threads()
    end

    test "memory tools are classified as support tools (P0-2)" do
      opts = Domain.default_opts(model: nil, stream_options: %{})
      matcher = Keyword.fetch!(opts, :support_tool_matcher)

      assert matcher.(%LemonAgent.Types.AgentTool{name: "memory_write_file"})
      assert matcher.(%LemonAgent.Types.AgentTool{name: "memory_read_file"})
      refute matcher.(%LemonAgent.Types.AgentTool{name: "speak"})
    end

    test "a dead AI task unwedges the thread (P0-4)" do
      Application.put_env(:lemon_sim_ui, :philosopher_chat_modules, %{
        Domain.modules()
        | decider: PhilosopherChatTest.KillingStubDecider
      })

      {:ok, thread_id} = PhilosopherChat.create_thread("Fragile", ["socrates"])
      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "hello")

      drive_pending_turn(thread_id)

      # The decider kills the task; the DOWN handler must clear typing/ai_ref.
      wait_until(fn ->
        {:ok, view} = PhilosopherChat.view(thread_id)
        view.typing == nil and view.ai_busy == false
      end)

      # The thread accepts new turns again.
      assert {:ok, %{scheduled: "socrates"}} = PhilosopherChat.nudge(thread_id, "socrates")

      cleanup_threads()
    end

    test "memories rejects path traversal agent ids (P0-6)" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Traversal", ["socrates"])

      assert {:error, :not_a_member} = PhilosopherChat.memories(thread_id, "../../../etc/passwd")
      assert {:error, :not_a_member} = PhilosopherChat.memories(thread_id, "you")
      assert {:error, :not_a_member} = PhilosopherChat.memories(thread_id, "zeus")

      cleanup_threads()
    end

    test "scheduling a turn persists the advanced rng state (P1-7)" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Entropy", ["socrates"])
      initial_rng = PhilosopherChat.get_thread(thread_id).rng_state

      assert {:ok, %{scheduled: "socrates"}} = PhilosopherChat.nudge(thread_id, "socrates")

      new_rng = PhilosopherChat.get_thread(thread_id).rng_state
      assert new_rng != nil
      assert new_rng != initial_rng

      cleanup_threads()
    end

    test "restart keeps the persisted pending turn and still fires it (P1-10)" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Reboot", ["socrates"])
      LemonCore.Bus.subscribe(PhilosopherChat.topic(thread_id))

      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "are you there?")
      assert %{actor_id: "socrates"} = PhilosopherChat.get_thread(thread_id).pending_turn

      pid = thread_server_pid(thread_id)
      Process.exit(pid, :kill)
      Process.sleep(100)

      # The server restarts from the store; the pending turn must survive.
      assert {:ok, _view} = PhilosopherChat.view(thread_id)
      assert %{actor_id: "socrates"} = PhilosopherChat.get_thread(thread_id).pending_turn

      drive_pending_turn(thread_id)

      assert_receive %LemonCore.Event{
                       type: :philosopher_chat_update,
                       payload: %{type: "message", message: %{author: "socrates"}}
                     },
                     2_000

      cleanup_threads()
    end

    test "hourly cap blocks nudges" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Capped", ["socrates"])
      now = System.system_time(:millisecond)
      cap = Pacing.hourly_cap("relaxed")
      pid = thread_server_pid(thread_id)

      :sys.replace_state(pid, fn server_state ->
        world = server_state.thread.game_state.world

        messages =
          for i <- 1..cap do
            %{seq: i, author: "socrates", text: "msg #{i}", at_ms: now}
          end

        world = %{world | messages: messages, next_seq: cap + 1}
        game_state = LemonSim.Kernel.State.put_world(server_state.thread.game_state, world)
        put_in(server_state[:thread].game_state, game_state)
      end)

      assert {:error, :cooldown_active} = PhilosopherChat.nudge(thread_id, "socrates")

      cleanup_threads()
    end

    test "user message posted during an agent turn gets a reply scheduled (review-2 P0-2)" do
      Application.put_env(:lemon_sim_ui, :philosopher_chat_modules, %{
        Domain.modules()
        | decider: PhilosopherChatTest.BlockingStubDecider
      })

      {:ok, thread_id} = PhilosopherChat.create_thread("Deferred", ["socrates"])

      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "first")
      drive_pending_turn(thread_id)

      wait_until(fn ->
        Task.Supervisor.children(LemonSimUi.PhilosopherChat.AiTaskSupervisor) != []
      end)

      [task_pid] = Task.Supervisor.children(LemonSimUi.PhilosopherChat.AiTaskSupervisor)

      # The in-flight turn was computed from a snapshot that does not include
      # this message; its reply must be deferred, never dropped.
      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "second")
      send(task_pid, :go)

      wait_until(fn ->
        {:ok, view} = PhilosopherChat.view(thread_id)
        Enum.any?(view.messages, &(&1.author == "socrates"))
      end)

      wait_until(fn -> PhilosopherChat.get_thread(thread_id).pending_turn != nil end)
      assert %{actor_id: "socrates"} = PhilosopherChat.get_thread(thread_id).pending_turn

      cleanup_threads()
    end

    test "consecutive AI failures stall the agent instead of retrying forever (review-2 P0-1)" do
      Application.put_env(:lemon_sim_ui, :philosopher_chat_modules, %{
        Domain.modules()
        | decider: PhilosopherChatTest.KillingStubDecider
      })

      {:ok, thread_id} = PhilosopherChat.create_thread("Storm", ["socrates"])
      LemonCore.Bus.subscribe(PhilosopherChat.topic(thread_id))

      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "hello")

      # Each drive kills the AI task: failures 1 and 2 arm a backoff retry,
      # the third consecutive failure stalls the agent. Waiting on the
      # server's consecutive_failures counter (not the store) avoids racing
      # the persist of the freshly armed retry.
      for attempt <- 1..2 do
        drive_pending_turn(thread_id)

        wait_until(fn ->
          :sys.get_state(thread_server_pid(thread_id)).consecutive_failures == attempt
        end)
      end

      drive_pending_turn(thread_id)

      assert_receive %LemonCore.Event{
                       type: :philosopher_chat_update,
                       payload: %{type: "agent_stalled", agent_id: "socrates", reason: reason}
                     },
                     2_000

      assert is_binary(reason)
      assert PhilosopherChat.get_thread(thread_id).pending_turn == nil

      {:ok, view} = PhilosopherChat.view(thread_id)
      assert view.typing == nil
      assert view.ai_busy == false

      cleanup_threads()
    end

    test "a turn that cannot start (AI slots full) is retried, not dropped (review-2 P2-18)" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Busy", ["socrates"])
      LemonCore.Bus.subscribe(PhilosopherChat.topic(thread_id))

      # Occupy every AI slot so start_child returns {:error, :max_children}.
      slots = Application.get_env(:lemon_sim_ui, :philosopher_chat_ai_concurrency, 4)

      blockers =
        for _ <- 1..slots do
          {:ok, pid} =
            Task.Supervisor.start_child(LemonSimUi.PhilosopherChat.AiTaskSupervisor, fn ->
              receive do
                :release -> :ok
              end
            end)

          pid
        end

      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "hello?")
      drive_pending_turn(thread_id)

      # The turn could not start; it must be re-armed, not eaten.
      wait_until(fn -> PhilosopherChat.get_thread(thread_id).pending_turn != nil end)

      # Free the slots; the retry timer starts the turn and the stub speaks.
      Enum.each(blockers, &send(&1, :release))

      assert_receive %LemonCore.Event{
                       type: :philosopher_chat_update,
                       payload: %{type: "message", message: %{author: "socrates"}}
                     },
                     5_000

      cleanup_threads()
    end

    test "events expose an epoch that changes across a server restart (review-2 P1-2)" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Epoch", ["socrates"])

      assert {:ok, %{events: [], epoch: epoch1, latest_seq: 0}} =
               PhilosopherChat.events(thread_id, 0)

      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "one")
      assert {:ok, %{epoch: ^epoch1, latest_seq: 1}} = PhilosopherChat.events(thread_id, 0)

      pid = thread_server_pid(thread_id)
      Process.exit(pid, :kill)
      Process.sleep(100)

      # Restarted from the store: event_seq resets to 0, so the epoch MUST
      # change for cursor clients to notice and rewind.
      assert {:ok, _view} = PhilosopherChat.view(thread_id)
      assert {:ok, %{epoch: epoch2, latest_seq: 0}} = PhilosopherChat.events(thread_id, 0)
      assert is_binary(epoch2)
      assert epoch2 != epoch1

      cleanup_threads()
    end
  end

  describe "api hardening" do
    test "duplicate client_msg_id returns the existing message without reposting" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Idem", ["socrates"])

      assert {:ok, view1} = PhilosopherChat.post_user_message(thread_id, "hello", "cm-1")
      refute Map.get(view1, :duplicate)

      assert {:ok, view2} = PhilosopherChat.post_user_message(thread_id, "hello again", "cm-1")
      assert view2.duplicate == true
      assert length(view2.messages) == 1
      assert view2.message.text == "hello"

      cleanup_threads()
    end

    test "broadcast log supports a since cursor" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Cursor", ["socrates"])

      assert {:ok, %{events: []}} = PhilosopherChat.events(thread_id, 0)

      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "one")

      assert {:ok, %{events: [%{event_seq: 1, type: "message"}]}} =
               PhilosopherChat.events(thread_id, 0)

      assert {:ok, %{events: []}} = PhilosopherChat.events(thread_id, 1)

      cleanup_threads()
    end
  end

  defp hitting_chatter_seed do
    Enum.find_value(1..10_000, fn n ->
      seed = :rand.seed_s(:exsss, {n, n, n}) |> :rand.export_seed_s()
      {hit, _} = Pacing.continue_chatter?("relaxed", seed)
      if hit, do: seed
    end)
  end

  describe "pubsub" do
    test "messages are broadcast on the thread topic" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Radio", ["camus"])
      LemonCore.Bus.subscribe(PhilosopherChat.topic(thread_id))

      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "The plague is in the room.")

      assert_receive %LemonCore.Event{
                       type: :philosopher_chat_update,
                       payload: %{type: "message"}
                     },
                     500

      cleanup_threads()
    end
  end
end
