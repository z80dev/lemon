defmodule CodingAgent.Session.NavigateLabelTest do
  @moduledoc """
  Native-session branch switching, entry labels and fork-from-entry through the
  control-plane provider, for live sessions and for sessions with no process.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.{ControlPlaneProvider, Session, SessionManager, SettingsManager}
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent}

  # A native lifecycle with a message barrier between initialization (which has
  # loaded and persisted the journal) and ownership publication.
  defmodule PausedStartup do
    use GenServer

    def init(opts) do
      Process.flag(:trap_exit, true)
      observer = Keyword.fetch!(opts, :observer)

      CodingAgent.Session.Ownership.initialize(opts, fn opts ->
        {:ok, state, _report} = CodingAgent.Session.Lifecycle.initialize(opts, self())
        send(observer, {:journal_loaded, self()})

        receive do
          :publish_owner -> {:ok, state}
        end
      end)
    end

    def handle_call(request, from, state),
      do: CodingAgent.Session.handle_call(request, from, state)

    def handle_info(message, state), do: CodingAgent.Session.handle_info(message, state)
    def terminate(reason, state), do: CodingAgent.Session.terminate(reason, state)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-navigate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, ".lemon"))
    # Keep recall and background fact extraction out of this journal fixture.
    File.write!(
      Path.join([root, ".lemon", "config.toml"]),
      "[memory]\nauto_recall = false\n[features]\nsession_search = \"off\"\n"
    )

    key = "agent:navigate-test-#{System.unique_integer([:positive])}:main"
    fork_key = "agent:navigate-fork-#{System.unique_integer([:positive])}:main"

    on_exit(fn ->
      LemonCore.SessionLifecycle.delete(key)
      LemonCore.ChatStateStore.delete(key)
      LemonCore.ChatStateStore.delete(fork_key)
      File.rm_rf!(root)
      File.rm_rf!(SessionManager.get_session_dir(root))
    end)

    %{root: root, key: key, fork_key: fork_key}
  end

  describe "live session" do
    test "a prompt after navigating sees the new branch's history", ctx do
      session = start_live(ctx)
      prompt(session, "first")
      prompt(session, "alpha")
      alpha_answer = entry_id(session, "assistant", "answer to: alpha")
      first_answer = entry_id(session, "assistant", "answer to: first")

      assert {:ok, %{"leafId" => ^first_answer, "prompt" => nil, "summarizing" => false}} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, first_answer, [])

      assert Enum.map(Session.get_messages(session), & &1.role) == [:user, :assistant]

      prompt(session, "beta")
      assert_received {:provider_texts, texts}
      assert texts == ["first", "answer to: first", "beta"]

      # The abandoned branch stays in the tree.
      assert {:ok, tree} = ControlPlaneProvider.session_tree(ctx.key, ctx.root, [])
      assert Enum.any?(tree["entries"], &(&1["id"] == alpha_answer and not &1["isActive"]))
    end

    test "unknown entries are refused, a streaming session is busy, and an unstarted summary is not claimed",
         ctx do
      parent = self()

      stream = fn _model, _context, _opts ->
        send(parent, {:stream_started, self()})

        receive do
          :release_stream -> {:ok, events("slow answer")}
        end
      end

      session = start_live(ctx, stream)
      prompt(session, "seed", wait: false)
      assert_receive {:stream_started, provider}, 5_000
      target = entry_id(session, "user", "seed")

      assert {:error, :busy} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, target, [])

      send(provider, :release_stream)
      wait_idle(session)

      assert {:error, :entry_not_found} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, "missing", [])

      # Staying on the current leaf abandons nothing, so no summary is claimed.
      answer = entry_id(session, "assistant", "slow answer")

      assert {:ok, %{"leafId" => ^answer, "summarizing" => false}} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, answer, summarize: true)
    end

    test "labels appear in the tree, clear again and never change the context", ctx do
      session = start_live(ctx)
      prompt(session, "first")
      answer = entry_id(session, "assistant", "answer to: first")
      before = Enum.map(Session.get_messages(session), &{&1.role, &1.content})

      assert {:ok, %{"entryId" => ^answer, "label" => "good idea"}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, answer, "good idea")

      assert tree_label(ctx, answer) == "good idea"
      assert Enum.map(Session.get_messages(session), &{&1.role, &1.content}) == before

      assert {:ok, %{"label" => nil}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, answer, nil)

      assert tree_label(ctx, answer) == nil

      secret = "sk-" <> String.duplicate("a", 24)

      assert {:ok, %{"label" => receipt}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, answer, "key #{secret}")

      refute receipt =~ secret
      refute tree_label(ctx, answer) =~ secret

      assert {:error, :entry_not_found} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, "missing", "x")
    end
  end

  describe "file ownership admission" do
    test "mutations wait through startup persistence until live ownership is published", ctx do
      {path, ids} = durable_tree(ctx)
      opts = Keyword.put(resume_opts(ctx, path), :observer, self())

      startup =
        Task.async(fn ->
          {:ok, session} = GenServer.start_link(PausedStartup, opts)
          Process.unlink(session)
          {:ok, session}
        end)

      assert_receive {:journal_loaded, session}, 5_000
      on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

      plan =
        Task.async(fn ->
          ControlPlaneProvider.session_plan(ctx.key, ctx.root, :enter, [])
        end)

      await_admission(path)

      label =
        Task.async(fn ->
          ControlPlaneProvider.session_label(ctx.key, ctx.root, ids.alpha, "during startup")
        end)

      navigation =
        Task.async(fn ->
          ControlPlaneProvider.session_navigate(ctx.key, ctx.root, ids.first_answer, [])
        end)

      await_admission(path, 3)
      send(session, :publish_owner)
      assert {:ok, ^session} = Task.await(startup)
      assert {:ok, %{"mode" => "plan"}} = Task.await(plan)
      assert {:ok, %{"label" => "during startup"}} = Task.await(label)
      assert {:ok, %{"leafId" => leaf}} = Task.await(navigation)
      assert leaf == ids.first_answer

      live = Session.get_state(session).session_manager
      assert SessionManager.labels(live)[ids.alpha] == "during startup"
      assert Enum.any?(SessionManager.entries(live), &(&1.id == ids.alpha_answer))
      assert {:ok, saved} = SessionManager.load_from_file(path)
      assert saved.leaf_id == live.leaf_id
      assert SessionManager.labels(saved) == SessionManager.labels(live)
      assert length(SessionManager.entries(saved)) == length(SessionManager.entries(live))
    end

    test "a queued native resume sees stopped navigation and labels before loading", ctx do
      {path, ids} = durable_tree(ctx)
      opts = resume_opts(ctx, path)

      startup =
        CodingAgent.Session.Ownership.with_file(path, fn ->
          startup =
            Task.async(fn ->
              {:ok, session} = Session.start_link(opts)
              Process.unlink(session)
              {:ok, session}
            end)

          await_admission(path)

          assert {:ok, %{"leafId" => leaf}} =
                   ControlPlaneProvider.session_navigate(ctx.key, ctx.root, ids.first_answer, [])

          assert leaf == ids.first_answer

          assert {:ok, %{"label" => "retained"}} =
                   ControlPlaneProvider.session_label(ctx.key, ctx.root, ids.alpha, "retained")

          startup
        end)

      assert {:ok, session} = Task.await(startup, 5_000)
      on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
      Session.subscribe(session)

      manager = Session.get_state(session).session_manager
      assert SessionManager.labels(manager)[ids.alpha] == "retained"
      assert Enum.any?(SessionManager.entries(manager), &(&1.id == ids.alpha_answer))
      prompt(session, "after resume")
      assert_received {:provider_texts, ["first", "answer to: first", "after resume"]}
    end

    test "an unregistered live owner receives alias mutations without losing appended history",
         ctx do
      {path, ids} = durable_tree(ctx)
      session = start_resumed(ctx, path)
      prompt(session, "new tail")

      assert_received {:provider_texts,
                       ["first", "answer to: first", "alpha", "answer to: alpha", "new tail"]}

      tail = entry_id(session, "assistant", "answer to: new tail")

      assert {:ok, %{"label" => "live bookmark"}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, tail, "live bookmark")

      manager = Session.get_state(session).session_manager
      assert SessionManager.labels(manager)[tail] == "live bookmark"

      assert {:ok, %{"leafId" => leaf}} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, ids.first_answer, [])

      assert leaf == ids.first_answer
      assert {:ok, saved} = SessionManager.load_from_file(path)
      assert Enum.any?(SessionManager.entries(saved), &(&1.id == tail))
      assert SessionManager.labels(saved)[tail] == "live bookmark"

      assert Enum.map(Session.get_messages(session), &message_text/1) ==
               ["first", "answer to: first"]
    end

    test "reset relinquishes the old journal and owns the new one", ctx do
      {old_path, ids} = durable_tree(ctx)
      session = start_resumed(ctx, old_path)
      assert :ok = Session.reset(session)

      assert {:ok, %{"label" => "archived"}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, ids.alpha, "archived")

      assert SessionManager.labels(Session.get_state(session).session_manager) == %{}
      assert {:ok, archived} = SessionManager.load_from_file(old_path)
      assert SessionManager.labels(archived)[ids.alpha] == "archived"

      new_path = bind_resume_token(ctx, session)
      refute new_path == old_path
      target = Session.get_state(session).session_manager.leaf_id

      assert {:ok, %{"label" => "new journal"}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, target, "new journal")

      assert SessionManager.labels(Session.get_state(session).session_manager)[target] ==
               "new journal"

      assert {:error, {:already_started, ^session}} =
               Task.async(fn -> Session.start_link(resume_opts(ctx, new_path)) end)
               |> Task.await(5_000)
    end

    test "a second native startup cannot rewrite a live owner's journal", ctx do
      {path, _ids} = durable_tree(ctx)
      session = start_resumed(ctx, path)
      assert {:ok, before} = File.read(path)

      assert {:error, {:already_started, ^session}} =
               Task.async(fn -> Session.start_link(resume_opts(ctx, path)) end)
               |> Task.await(5_000)

      assert File.read!(path) == before
    end
  end

  test "queued live mutations return their own receipts rather than a later state", ctx do
    session = start_live(ctx)
    prompt(session, "first")
    prompt(session, "alpha")
    first = entry_id(session, "assistant", "answer to: first")
    alpha = entry_id(session, "assistant", "answer to: alpha")

    :sys.suspend(session)
    on_exit(fn -> if Process.alive?(session), do: :sys.resume(session) end)

    first_label =
      Task.async(fn -> ControlPlaneProvider.session_label(ctx.key, ctx.root, first, "one") end)

    await_calls(session, 1)

    second_label =
      Task.async(fn -> ControlPlaneProvider.session_label(ctx.key, ctx.root, first, "two") end)

    await_calls(session, 2)
    :sys.resume(session)
    assert {:ok, %{"label" => "one"}} = Task.await(first_label)
    assert {:ok, %{"label" => "two"}} = Task.await(second_label)
    assert tree_label(ctx, first) == "two"

    :sys.suspend(session)

    first_navigation =
      Task.async(fn -> ControlPlaneProvider.session_navigate(ctx.key, ctx.root, first, []) end)

    await_calls(session, 1)

    second_navigation =
      Task.async(fn -> ControlPlaneProvider.session_navigate(ctx.key, ctx.root, alpha, []) end)

    await_calls(session, 2)
    :sys.resume(session)
    assert {:ok, %{"leafId" => ^first}} = Task.await(first_navigation)
    assert {:ok, %{"leafId" => ^alpha}} = Task.await(second_navigation)
    assert Session.get_state(session).session_manager.leaf_id == alpha
  end

  describe "session without a process" do
    test "navigation moves the leaf on disk and the next prompt follows it", ctx do
      {path, ids} = durable_tree(ctx)

      assert {:ok, %{"leafId" => leaf, "prompt" => nil, "summarizing" => false}} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, ids.first_answer,
                 summarize: true
               )

      assert leaf == ids.first_answer
      assert {:ok, loaded} = SessionManager.load_from_file(path)
      assert loaded.leaf_id == ids.first_answer
      # Both branches are still on disk.
      assert Enum.any?(SessionManager.entries(loaded), &(&1.id == ids.alpha_answer))

      session = start_resumed(ctx, path)
      prompt(session, "beta")
      assert_received {:provider_texts, ["first", "answer to: first", "beta"]}
    end

    test "a user message lands before itself; a session starting with one lands on the root",
         ctx do
      {path, ids} = durable_tree(ctx)

      assert {:ok, %{"leafId" => leaf, "prompt" => "alpha"}} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, ids.alpha, [])

      assert leaf == ids.first_answer

      assert {:error, :entry_not_found} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, "missing", [])

      bare =
        ctx.root
        |> SessionManager.new()
        |> SessionManager.append_message(%{"role" => "user", "content" => "only prompt"})

      root_path = CodingAgent.Session.Presentation.session_file_path(bare.header.id, ctx.root)
      :ok = SessionManager.save_to_file(root_path, bare)
      [only] = SessionManager.entries(bare)

      :ok =
        LemonCore.ChatStateStore.put(ctx.key, %LemonCore.ChatState{
          last_engine: "lemon",
          last_resume_token: bare.header.id,
          updated_at: System.system_time(:millisecond)
        })

      assert {:ok, %{"leafId" => nil, "prompt" => "only prompt"}} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, only.id, [])

      assert {:ok, loaded} = SessionManager.load_from_file(root_path)
      assert loaded.leaf_id == nil
      assert SessionManager.build_session_context(loaded).messages == []
      refute path == root_path
    end

    test "labels persist, resolve to the latest value and never change the context", ctx do
      {path, ids} = durable_tree(ctx)
      {:ok, before} = SessionManager.load_from_file(path)

      assert {:ok, %{"label" => "keep"}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, ids.alpha, "keep")

      assert {:ok, %{"label" => "keep v2"}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, ids.alpha, "keep v2")

      assert tree_label(ctx, ids.alpha) == "keep v2"

      assert {:ok, %{"label" => nil}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, ids.alpha, "")

      assert tree_label(ctx, ids.alpha) == nil

      assert {:ok, loaded} = SessionManager.load_from_file(path)

      assert SessionManager.build_session_context(loaded).messages ==
               SessionManager.build_session_context(before).messages
    end

    test "fork from an entry copies history up to and including it", ctx do
      {_path, ids} = durable_tree(ctx)

      assert :ok =
               ControlPlaneProvider.session_fork(ctx.key, ctx.root, ctx.fork_key,
                 entry_id: ids.first_answer
               )

      assert {:ok, entries} = ControlPlaneProvider.session_history(ctx.fork_key, ctx.root)
      forked = Enum.map(entries, & &1.id)
      assert ids.first in forked and ids.first_answer in forked
      refute Enum.any?([ids.alpha, ids.alpha_answer, ids.beta], &(&1 in forked))

      # The source keeps its own leaf.
      assert {:ok, tree} = ControlPlaneProvider.session_tree(ctx.key, ctx.root, [])
      assert tree["leafId"] == ids.alpha_answer

      assert {:error, :entry_not_found} =
               ControlPlaneProvider.session_fork(ctx.key, ctx.root, "agent:other-fork:main",
                 entry_id: "missing"
               )

      assert LemonCore.ChatStateStore.get("agent:other-fork:main") == nil
    end
  end

  # first ─ first_answer ┬─ alpha ─ alpha_answer   (active leaf)
  #                      └─ beta ─ beta_answer
  defp durable_tree(ctx) do
    session = start_live(ctx)
    prompt(session, "first")
    prompt(session, "alpha")
    first_answer = entry_id(session, "assistant", "answer to: first")
    :ok = Session.navigate_tree(session, first_answer, summarize_abandoned: false)
    prompt(session, "beta")
    alpha_answer = entry_id(session, "assistant", "answer to: alpha")
    :ok = Session.navigate_tree(session, alpha_answer, summarize_abandoned: false)

    ids = %{
      first: entry_id(session, "user", "first"),
      first_answer: first_answer,
      alpha: entry_id(session, "user", "alpha"),
      alpha_answer: alpha_answer,
      beta: entry_id(session, "user", "beta")
    }

    path = bind_resume_token(ctx, session)
    stop_supervised!(Session)

    {path, ids}
  end

  # What the run executor does after a turn: persist and map the key to the file.
  defp bind_resume_token(ctx, session) do
    assert :ok = Session.save(session)
    state = Session.get_state(session)

    :ok =
      LemonCore.ChatStateStore.put(ctx.key, %LemonCore.ChatState{
        last_engine: "lemon",
        last_resume_token: state.session_manager.header.id,
        updated_at: System.system_time(:millisecond)
      })

    state.session_file
  end

  defp start_live(ctx, stream \\ nil) do
    session =
      start_supervised!(
        {Session,
         [
           cwd: ctx.root,
           workspace_dir: Path.join(ctx.root, "workspace"),
           model: model(),
           stream_fn: stream || echo_stream(self()),
           session_key: ctx.key,
           register: true,
           settings_manager: %{SettingsManager.load(ctx.root) | compaction_enabled: false}
         ]}
      )

    Session.subscribe(session)
    session
  end

  defp start_resumed(ctx, path) do
    session = start_supervised!({Session, resume_opts(ctx, path)})

    Session.subscribe(session)
    session
  end

  defp resume_opts(ctx, path) do
    [
      cwd: ctx.root,
      workspace_dir: Path.join(ctx.root, "workspace"),
      model: model(),
      stream_fn: echo_stream(self()),
      session_file: path,
      settings_manager: %{SettingsManager.load(ctx.root) | compaction_enabled: false}
    ]
  end

  # Barrier on a queued admission, not elapsed time: startup has actually reached
  # the shared lock before the stopped mutation is allowed to proceed.
  defp await_admission(path, count \\ 1) do
    await_barrier(fn ->
      locks = :sys.get_state(CodingAgent.MutationLock).locks

      case locks[{:native_session, Path.expand(path)}] do
        nil -> false
        lock -> :queue.len(lock.waiters) >= count
      end
    end)
  end

  defp await_calls(session, count) do
    await_barrier(fn ->
      {:messages, messages} = Process.info(session, :messages)
      Enum.count(messages, &match?({:"$gen_call", _, _}, &1)) >= count
    end)
  end

  defp await_barrier(fun) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_barrier(fun, deadline)
  end

  defp await_barrier(fun, deadline) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "barrier was not reached"
      :erlang.yield()
      await_barrier(fun, deadline)
    end
  end

  defp prompt(session, text, opts \\ []) do
    flush_texts()
    assert :ok = Session.prompt(session, text)
    if Keyword.get(opts, :wait, true), do: wait_idle(session)
  end

  defp wait_idle(session) do
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000
    refute Session.get_state(session).is_streaming
  end

  defp flush_texts do
    receive do
      {:provider_texts, _} -> flush_texts()
    after
      0 -> :ok
    end
  end

  defp tree_label(ctx, id) do
    {:ok, tree} = ControlPlaneProvider.session_tree(ctx.key, ctx.root, [])
    Enum.find(tree["entries"], &(&1["id"] == id))["label"]
  end

  defp entry_id(session, role, text) do
    entry = find_entry(session, role, text)
    assert entry != nil
    entry.id
  end

  defp find_entry(session, role, text) do
    session
    |> Session.get_state()
    |> Map.fetch!(:session_manager)
    |> SessionManager.entries()
    |> Enum.find(fn entry ->
      entry.type == :message and message_role(entry.message) == role and
        message_text(entry.message) == text
    end)
  end

  defp message_role(message), do: to_string(field(message, :role))

  defp message_text(message) do
    case field(message, :content) do
      text when is_binary(text) -> text
      blocks -> Enum.map_join(blocks, "", &(field(&1, :text) || ""))
    end
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  # Replies "answer to: <last user text>" and reports the texts it was sent.
  defp echo_stream(parent) do
    fn _model, context, _opts ->
      texts = Enum.map(context.messages, &message_text/1)
      send(parent, {:provider_texts, texts})
      {:ok, events("answer to: #{List.last(texts)}")}
    end
  end

  defp model,
    do: %Model{
      id: "navigate-test",
      name: "Navigate Test",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 4096
    }

  defp events(text) do
    message = %AssistantMessage{
      content: [%TextContent{text: text}],
      api: :mock,
      provider: :mock_provider,
      model: "navigate-test",
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }

    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.push(stream, {:done, message.stop_reason, message})
      LemonAi.EventStream.complete(stream, message)
    end)

    stream
  end
end
