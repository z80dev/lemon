defmodule LemonSim.Examples.PhilosopherChatTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.PhilosopherChat
  alias LemonSim.Examples.PhilosopherChat.{ActionSpace, Pacing, Persona, Updater}
  alias LemonSim.Kernel.State

  @members ["you", "socrates", "nietzsche", "wittgenstein"]

  defp fresh_thread(opts \\ []) do
    PhilosopherChat.initial_state("thread_test", "The Symposium, but rude", @members, opts)
  end

  describe "persona roster" do
    test "seeds the expected contacts with full identity data" do
      ids = Persona.ids()

      assert length(ids) >= 18
      assert "socrates" in ids
      assert "nietzsche" in ids
      assert "wittgenstein" in ids
      assert "camus" in ids
      assert "kafka" in ids
      assert "weil" in ids

      for id <- ids do
        persona = Persona.get(id)
        assert persona.name != nil
        assert persona.doctrine != nil
        assert persona.style != nil
        assert persona.emoji != nil
        assert persona.color != nil
        assert persona.relationships != nil
      end
    end

    test "unknown id returns nil" do
      assert Persona.get("diogenes_is_here") == nil
    end
  end

  describe "updater" do
    test "appends user and agent messages in order with seq" do
      state = fresh_thread()

      {:ok, state, _} = PhilosopherChat.post_message(state, "you", "Is the unexamined life worth living?")
      {:ok, state, _} = PhilosopherChat.post_message(state, "socrates", "Ask yourself what you mean by 'worth.'")
      {:ok, state, _} = PhilosopherChat.post_message(state, "nietzsche", "I have opinions about that.")

      messages = get_in(state.world, [:messages])
      assert length(messages) == 3
      assert Enum.map(messages, & &1.seq) == [1, 2, 3]
      assert Enum.map(messages, & &1.author) == ["you", "socrates", "nietzsche"]
      assert hd(messages).text == "Is the unexamined life worth living?"
      assert state.world.last_author == "nietzsche"
      assert state.world.next_seq == 4
    end

    test "rejects non-members" do
      state = fresh_thread()
      assert {:error, :not_a_member} = PhilosopherChat.post_message(state, "hume", "Hello?")
    end

    test "rejects empty and oversized messages" do
      state = fresh_thread()
      assert {:error, :empty_message} = PhilosopherChat.post_message(state, "you", "   ")
      assert {:error, :message_too_long} = PhilosopherChat.post_message(state, "you", String.duplicate("a", 1401))
    end

    test "rejects messages when thread is not active" do
      state = fresh_thread() |> then(&elem(PhilosopherChat.set_status(&1, "paused"), 1))
      assert {:error, :thread_not_active} = PhilosopherChat.post_message(state, "you", "hello?")
    end

    test "status changes are validated" do
      state = fresh_thread()
      assert {:ok, state} = PhilosopherChat.set_status(state, "paused")
      assert state.world.status == "paused"
      assert {:ok, state} = PhilosopherChat.set_status(state, "active")
      assert {:error, {:invalid_status, "suspended"}} = PhilosopherChat.set_status(state, "suspended")
    end

    test "unknown events are rejected" do
      state = fresh_thread()
      event = LemonSim.Kernel.Event.new("alien_invasion", %{"who" => "mars"})
      assert {:error, {:unknown_event, "alien_invasion"}} = Updater.apply_event(state, event, [])
    end
  end

  describe "action space" do
    test "exposes speak + memory tools for an active agent turn" do
      state = fresh_thread() |> PhilosopherChat.with_actor("socrates")

      tmp = Path.join(System.tmp_dir!(), "philosopher_chat_mem_#{System.unique_integer([:positive])}")
      {:ok, tools} = ActionSpace.tools(state, memory_root: tmp, memory_namespace: "thread_x")

      names = Enum.map(tools, & &1.name)
      assert "speak" in names
      assert "memory_write_file" in names
      assert "memory_read_file" in names
      assert "memory_list_files" in names

      speak = Enum.find(tools, &(&1.name == "speak"))
      assert {:ok, result} = speak.execute.("id", %{"message" => "Tell me, what is justice?"}, nil, fn _ -> :ok end)
      event = result.details["event"]
      assert event.kind == "message_posted"
      assert event.payload["author"] == "socrates"
    end

    test "no tools for the user or unknown actors" do
      state = fresh_thread() |> PhilosopherChat.with_actor("you")
      assert {:ok, []} = ActionSpace.tools(state, [])

      state = fresh_thread() |> PhilosopherChat.with_actor("hume")
      assert {:ok, []} = ActionSpace.tools(state, [])
    end

    test "no tools when paused" do
      state = fresh_thread() |> then(&elem(PhilosopherChat.set_status(&1, "paused"), 1)) |> PhilosopherChat.with_actor("socrates")
      assert {:ok, []} = ActionSpace.tools(state, [])
    end

    test "speak truncates oversized messages instead of failing" do
      state = fresh_thread() |> PhilosopherChat.with_actor("socrates")
      {:ok, tools} = ActionSpace.tools(state, [])
      speak = Enum.find(tools, &(&1.name == "speak"))

      long = String.duplicate("a", 1500)
      assert {:ok, result} = speak.execute.("id", %{"message" => long}, nil, fn _ -> :ok end)
      text = result.details["event"].payload["text"]

      assert String.ends_with?(text, "…")
      assert byte_size(text) <= 1400
      assert String.length(text) >= 1390

      # End-to-end: the truncated text must survive the updater's
      # :message_too_long backstop and land in the world.
      {:ok, next_state, _} = PhilosopherChat.post_message(state, "socrates", text)
      assert List.last(next_state.world.messages).text == text
    end
  end

  describe "pacing" do
    test "picks mentioned agents over the pool" do
      state =
        fresh_thread()
        |> then(&elem(PhilosopherChat.post_message(&1, "you", "Wittgenstein, what is the use of this word?"), 1))

      rng = :rand.seed_s(:exsss, {101, 102, 103})
      {agent, _rng} = Pacing.pick_responder(state.world, rng)
      assert agent == "wittgenstein"
    end

    test "excludes the last speaker when a larger pool exists" do
      state =
        fresh_thread()
        |> then(&elem(PhilosopherChat.post_message(&1, "socrates", "Ask me anything."), 1))

      rng = :rand.seed_s(:exsss, {7, 7, 7})
      {agent, _rng} = Pacing.pick_responder(state.world, rng)
      assert agent != "socrates"
      assert agent in ["nietzsche", "wittgenstein"]
    end

    test "returns nil when no agents are members" do
      world = %{members: ["you"], messages: [], last_author: nil}
      rng = :rand.seed_s(:exsss, {1, 2, 3})
      assert {nil, _} = Pacing.pick_responder(world, rng)
    end

    test "delays and cooldowns respect pace" do
      rng = :rand.seed_s(:exsss, {1, 2, 3})
      {relaxed_delay, _} = Pacing.reply_delay_ms("relaxed", rng)
      {chatty_delay, rng2} = Pacing.reply_delay_ms("chatty", rng)
      assert relaxed_delay >= 25_000 and relaxed_delay <= 90_000
      assert chatty_delay >= 15_000 and chatty_delay <= 60_000
      assert Pacing.min_cooldown_ms("relaxed") == 20_000
      assert Pacing.min_cooldown_ms("chatty") == 12_000
      assert Pacing.max_chain("relaxed") == 2
      assert Pacing.hourly_cap("relaxed") == 30
      # same seed advances deterministically
      {chatty_delay2, _} = Pacing.reply_delay_ms("chatty", rng2)
      assert is_integer(chatty_delay2)
    end

    test "random draws advance the seed" do
      rng = :rand.seed_s(:exsss, {11, 22, 33})
      {a, rng2} = Pacing.rand_int(rng, 100)
      {b, _} = Pacing.rand_int(rng2, 100)
      assert is_integer(a) and a in 0..99
      assert is_integer(b) and b in 0..99
    end

    test "mentions match whole words only" do
      state = fresh_thread()

      {:ok, state, _} = PhilosopherChat.post_message(state, "you", "Of course you are human.")
      refute Pacing.mentioned?(state.world, "hume")

      {:ok, state, _} = PhilosopherChat.post_message(state, "you", "Hume, what say you?")
      assert Pacing.mentioned?(state.world, "hume")

      {:ok, state, _} = PhilosopherChat.post_message(state, "you", "Wittgenstein, your move.")
      assert Pacing.mentioned?(state.world, "wittgenstein")
    end
  end

  describe "projection" do
    test "thread projection returns members with persona metadata" do
      state = fresh_thread()
      {:ok, state, _} = PhilosopherChat.post_message(state, "you", "Hello, gentlemen.")
      projection = PhilosopherChat.thread_projection(state.world)

      assert projection.id == "thread_test"
      assert projection.status == "active"
      assert length(projection.members) == 4
      assert length(projection.messages) == 1

      socrates = Enum.find(projection.members, &(&1.id == "socrates"))
      assert socrates.name == "Socrates"
      assert socrates.emoji == "🏛️"
      assert socrates.is_user == false

      you = Enum.find(projection.members, &(&1.id == "you"))
      assert you.is_user == true
    end
  end

  describe "decision adapter" do
    alias LemonSim.Examples.PhilosopherChat.DecisionAdapter

    @empty_state %State{sim_id: "x", world: %{}}

    test "extracts an event from a speak decision" do
      event = LemonSim.Kernel.Event.new("message_posted", %{"author" => "socrates", "text" => "Hi"})
      decision = %{"type" => "tool_call", "result_details" => %{"event" => event}}
      assert {:ok, [^event]} = DecisionAdapter.to_events(decision, @empty_state, [])
    end

    test "memory-only turns produce no world events" do
      decision = %{"type" => "tool_call", "result_details" => %{"path" => "opinions.md", "bytes" => 4}}
      assert {:ok, []} = DecisionAdapter.to_events(decision, @empty_state, [])
    end

    test "unsupported decisions error" do
      assert {:error, {:unsupported_decision, "huh"}} = DecisionAdapter.to_events("huh", @empty_state, [])
    end
  end
end
