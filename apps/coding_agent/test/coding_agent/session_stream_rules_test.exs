defmodule CodingAgent.SessionStreamRules599Test do
  use ExUnit.Case, async: true

  alias CodingAgent.Session
  alias CodingAgent.SessionManager
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent}

  test "injection limits are independent lifetime counts, not current-branch counts" do
    alias CodingAgent.SessionManager.SessionEntry

    manager =
      SessionManager.new(System.tmp_dir!())
      |> SessionManager.append_entry(
        SessionEntry.custom("lemon.stream_rule", %{"version" => 1, "name" => "once"})
      )
      |> SessionManager.append_entry(
        SessionEntry.custom("lemon.stream_rule", %{"version" => 1, "name" => "twice"})
      )

    rules = [
      %{name: "once", injection_limit: 1},
      %{name: "twice", injection_limit: 2},
      %{name: "unused", injection_limit: 1}
    ]

    # Navigating to a point before the receipts cannot replenish the limits.
    manager = %{manager | leaf_id: nil}

    assert Enum.map(CodingAgent.Session.StreamRules.available(manager, rules), & &1.name) ==
             ["twice", "unused"]

    manager =
      SessionManager.append_entry(
        manager,
        SessionEntry.custom("lemon.stream_rule", %{"version" => 1, "name" => "twice"})
      )

    assert Enum.map(CodingAgent.Session.StreamRules.available(manager, rules), & &1.name) ==
             ["unused"]
  end

  @tag :tmp_dir
  test "matching output cancels, corrects, and never replenishes after compaction or resume", %{
    tmp_dir: cwd
  } do
    File.mkdir_p!(Path.join(cwd, ".lemon/rules"))

    File.write!(Path.join(cwd, ".lemon/rules/no-bad.md"), """
    ---
    streamPattern: BAD_TOKEN
    injectionLimit: 1
    ---
    Return GOOD_TOKEN instead.
    """)

    parent = self()
    counter = :counters.new(1, [:atomics])

    provider = fn _model, context, _options ->
      :counters.add(counter, 1, 1)
      call = :counters.get(counter, 1)
      text = if call == 2, do: "GOOD_TOKEN", else: "BAD_TOKEN"

      response = %AssistantMessage{
        role: :assistant,
        content: [%TextContent{type: :text, text: text}],
        stop_reason: :stop,
        api: :mock,
        provider: :mock_provider,
        model: "stream-rules-599"
      }

      {:ok, stream} = LemonAi.EventStream.start_link()
      send(parent, {:provider_call, call, context, stream})
      :ok = LemonAi.EventStream.push(stream, {:start, response})
      :ok = LemonAi.EventStream.push(stream, {:text_delta, 0, text, response})

      if call != 1 do
        :ok = LemonAi.EventStream.push(stream, {:done, :stop, response})
        LemonAi.EventStream.complete(stream, response)
      end

      {:ok, stream}
    end

    model = %Model{
      id: "stream-rules-599",
      name: "Stream rules fake",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://mock.invalid",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0, output: 0},
      context_window: 128_000,
      max_tokens: 4096
    }

    file = Path.join(cwd, "session.jsonl")
    :ok = SessionManager.save_to_file(file, SessionManager.new(cwd))
    opts = [cwd: cwd, model: model, stream_fn: provider, session_file: file]
    {:ok, session} = Session.start_link(opts)
    unsubscribe = Session.subscribe(session)
    :ok = Session.prompt(session, "Answer")
    assert_receive {:provider_call, 1, initial, first_stream}, 5_000
    refute inspect(initial) =~ "Return GOOD_TOKEN instead."
    assert_receive {:provider_call, 2, corrected, _}, 5_000
    assert inspect(corrected) =~ "system-interrupt"
    assert inspect(corrected) =~ "rule_violation"
    assert inspect(corrected) =~ "Return GOOD_TOKEN instead."

    assert {:error, :canceled} =
             LemonAi.EventStream.push(first_stream, {:text_delta, 0, "late", nil})

    await_end(session)

    assert Enum.any?(Session.get_messages(session), fn message ->
             match?(%AssistantMessage{content: [%TextContent{text: "GOOD_TOKEN"}]}, message)
           end)

    assert :ok = Session.compact(session, summary: "The answer was corrected.")

    assert Enum.count(
             SessionManager.entries(Session.get_state(session).session_manager),
             fn entry ->
               entry.type == :compaction
             end
           ) == 1

    :ok = Session.prompt(session, "Answer again")
    assert_receive {:provider_call, 3, _, _}, 5_000
    await_end(session)
    assert :counters.get(counter, 1) == 3
    state = Session.get_state(session)
    file = state.session_manager.file_path
    assert receipt_count(state.session_manager) == 1
    unsubscribe.()
    GenServer.stop(session)

    {:ok, resumed} = Session.start_link(Keyword.put(opts, :session_file, file))
    unsubscribe_resumed = Session.subscribe(resumed)
    :ok = Session.prompt(resumed, "Answer after restart")
    assert_receive {:provider_call, 4, _, _}, 5_000
    await_end(resumed)
    assert :counters.get(counter, 1) == 4
    assert receipt_count(Session.get_state(resumed).session_manager) == 1
    unsubscribe_resumed.()
    GenServer.stop(resumed)
  end

  defp receipt_count(manager) do
    Enum.count(SessionManager.entries(manager), fn entry ->
      entry.type == :custom and entry.custom_type == "lemon.stream_rule" and
        entry.data["name"] == "no-bad"
    end)
  end

  defp await_end(session) do
    receive do
      {:session_event, _, {:agent_end, _}, _cursor} ->
        # The owner processes agent_end before replying to this explicit barrier.
        refute Session.get_state(session).is_streaming

      {:session_event, _, {:error, reason, _}, _cursor} ->
        flunk("unexpected session error: #{inspect(reason)}")

      {:session_event, _, _, _cursor} ->
        await_end(session)
    after
      5_000 -> flunk("session did not finish")
    end
  end
end
