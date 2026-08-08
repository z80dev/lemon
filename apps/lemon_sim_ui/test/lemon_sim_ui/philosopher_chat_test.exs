defmodule PhilosopherChatTest.StubDecider do
  @moduledoc false
  @behaviour LemonSim.Kernel.Decider

  @impl true
  def decide(_context, tools, _opts) do
    case Enum.find(tools, &(&1.name == "speak")) do
      nil ->
        {:error, :no_speak_tool}

      tool ->
        case tool.execute.(
               "stub",
               %{"message" => "The unexamined life is not worth living, and I say this as one who examined it to the end."},
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

  alias LemonCore.Store
  alias LemonSim.Examples.PhilosopherChat, as: Domain
  alias LemonSimUi.PhilosopherChat
  alias LemonSimUi.PhilosopherChat.ThreadServer

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

    tmp = Path.join(System.tmp_dir!(), "philosopher_chat_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:lemon_sim_ui, :philosopher_chat_data_root, tmp)

    modules = %{Domain.modules() | decider: PhilosopherChatTest.StubDecider}
    Application.put_env(:lemon_sim_ui, :philosopher_chat_modules, modules)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value), do: Application.delete_env(:lemon_sim_ui, key), else: Application.put_env(:lemon_sim_ui, key, value)
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

  describe "coordinator" do
    test "creates a thread with validation" do
      assert {:ok, thread_id} = PhilosopherChat.create_thread("The Symposium", ["socrates", "nietzsche"])
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
      assert {:error, :duplicate_member} = PhilosopherChat.create_thread("Bad", ["socrates", "socrates"])
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

      # Drive the scheduled turn deterministically: grab the ThreadServer pid
      # and deliver the agent_turn message ourselves (the real timer would
      # take 25-90s; the server logic after the timer is identical).
      [{pid, _}] = Registry.lookup(LemonSimUi.PhilosopherChat.Registry, thread_id)
      thread = PhilosopherChat.get_thread(thread_id)
      ref = make_ref()
      send(pid, {:agent_turn, thread.pending_turn.actor_id, ref})

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
      {:ok, tools} = Domain.ActionSpace.tools(state,
        memory_root: PhilosopherChat.memory_root(),
        memory_namespace: PhilosopherChat.memory_namespace(thread_id)
      )
      writer = Enum.find(tools, &(&1.name == "memory_write_file"))
      assert {:ok, _} = writer.execute.("id", %{"path" => "opinions/hegel.md", "content" => "Hegel stands on his head."}, nil, fn _ -> :ok end)

      assert {:ok, %{files: files}} = PhilosopherChat.memories(thread_id, "marx")
      assert Enum.any?(files, &(&1.path == "index.md"))
      hegel = Enum.find(files, &(&1.path == "opinions/hegel.md"))
      assert hegel != nil
      assert String.contains?(hegel.content, "Hegel stands on his head")

      cleanup_threads()
    end
  end

  describe "pubsub" do
    test "messages are broadcast on the thread topic" do
      {:ok, thread_id} = PhilosopherChat.create_thread("Radio", ["camus"])
      LemonCore.Bus.subscribe(PhilosopherChat.topic(thread_id))

      assert {:ok, _} = PhilosopherChat.post_user_message(thread_id, "The plague is in the room.")

      assert_receive %LemonCore.Event{type: :philosopher_chat_update, payload: %{type: "message"}},
                     500
      cleanup_threads()
    end
  end
end
