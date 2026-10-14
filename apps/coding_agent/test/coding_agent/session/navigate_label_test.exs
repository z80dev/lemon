defmodule CodingAgent.Session.NavigateLabelTest do
  @moduledoc """
  Native-session branch switching, entry labels and fork-from-entry through the
  control-plane provider, for live sessions and for sessions with no process.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.{ControlPlaneProvider, Session, SessionManager, SettingsManager}
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent}

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-navigate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
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
      alpha = entry_id(session, "user", "alpha")

      assert {:ok, %{"leafId" => leaf, "prompt" => nil, "summarizing" => false} = receipt} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, first_answer, [])

      assert leaf == first_answer
      assert receipt["entryId"] == first_answer
      assert receipt["sessionId"] == Session.get_state(session).session_manager.header.id
      assert Enum.map(Session.get_messages(session), & &1.role) == [:user, :assistant]

      prompt(session, "beta")
      assert_received {:provider_texts, texts}
      assert texts == ["first", "answer to: first", "beta"]

      # The abandoned branch is still in the tree, and a user message lands
      # before itself and hands its text back for editing.
      assert {:ok, tree} = ControlPlaneProvider.session_tree(ctx.key, ctx.root, [])
      assert Enum.any?(tree["entries"], &(&1["id"] == alpha_answer and not &1["isActive"]))

      assert {:ok, %{"leafId" => ^first_answer, "prompt" => "alpha"}} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, alpha, [])

      prompt(session, "gamma")
      assert_received {:provider_texts, ["first", "answer to: first", "gamma"]}
    end

    test "the first user message lands before itself and :root empties the context", ctx do
      session = start_live(ctx)
      prompt(session, "first")
      first = entry_id(session, "user", "first")
      manager = Session.get_state(session).session_manager
      parent = SessionManager.get_entry(manager, first).parent_id

      assert {:ok, %{"leafId" => ^parent, "prompt" => "first"}} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, first, [])

      assert Session.get_messages(session) == []
      assert :ok = Session.navigate_tree(session, :root, summarize_abandoned: false)
      assert Session.get_state(session).session_manager.leaf_id == nil
      prompt(session, "fresh start")
      # Only the new prompt (plus its recalled-context footer) reaches the model.
      assert_received {:provider_texts, [only]}
      assert String.starts_with?(only, "fresh start")
    end

    test "unknown entries are refused and a streaming session is busy", ctx do
      parent = self()
      gate = :atomics.new(1, [])

      stream = fn _model, _context, _opts ->
        send(parent, :stream_started)
        wait_until(fn -> :atomics.get(gate, 1) == 1 end)
        {:ok, events("slow answer")}
      end

      session = start_live(ctx, stream)
      prompt(session, "seed", wait: false)
      assert_receive :stream_started, 5_000
      target = entry_id(session, "user", "seed")

      assert {:error, :busy} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, target, [])

      :atomics.put(gate, 1, 1)
      wait_idle(session)

      assert {:error, :entry_not_found} =
               ControlPlaneProvider.session_navigate(ctx.key, ctx.root, "missing", [])
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

      assert {:ok, %{"label" => "better"}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, answer, "better")

      assert tree_label(ctx, answer) == "better"

      assert {:ok, %{"label" => nil}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, answer, nil)

      assert tree_label(ctx, answer) == nil

      assert {:error, :entry_not_found} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, "missing", "x")

      prompt(session, "second")
      assert_received {:provider_texts, ["first", "answer to: first", "second"]}
    end
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

    test "unknown sessions are reported, not created", ctx do
      assert {:error, :session_not_found} =
               ControlPlaneProvider.session_navigate("agent:nobody:main", ctx.root, "x", [])

      assert {:error, :session_not_found} =
               ControlPlaneProvider.session_label("agent:nobody:main", ctx.root, "x", "y")
    end

    test "labels persist, resolve to the latest value and keep the active branch", ctx do
      {path, ids} = durable_tree(ctx)
      {:ok, before} = SessionManager.load_from_file(path)
      active_before = Enum.map(SessionManager.get_branch(before), & &1.id)

      assert {:ok, %{"label" => "keep"}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, ids.alpha, "keep")

      assert {:ok, %{"label" => "keep v2"}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, ids.alpha, "keep v2")

      assert {:ok, %{"label" => "other branch"}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, ids.beta, "other branch")

      assert tree_label(ctx, ids.alpha) == "keep v2"
      assert tree_label(ctx, ids.beta) == "other branch"

      assert {:ok, %{"label" => nil}} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, ids.alpha, "")

      assert tree_label(ctx, ids.alpha) == nil

      assert {:ok, loaded} = SessionManager.load_from_file(path)

      assert SessionManager.build_session_context(loaded).messages ==
               SessionManager.build_session_context(before).messages

      assert Enum.take(
               Enum.map(SessionManager.get_branch(loaded), & &1.id),
               length(active_before)
             ) ==
               active_before

      assert {:error, :entry_not_found} =
               ControlPlaneProvider.session_label(ctx.key, ctx.root, "missing", "x")
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

    test "a live source forks from an entry too", ctx do
      session = start_live(ctx)
      prompt(session, "first")
      prompt(session, "alpha")
      first_answer = entry_id(session, "assistant", "answer to: first")
      alpha = entry_id(session, "user", "alpha")
      bind_resume_token(ctx, session)

      assert :ok =
               ControlPlaneProvider.session_fork(ctx.key, ctx.root, ctx.fork_key,
                 entry_id: first_answer
               )

      assert {:ok, entries} = ControlPlaneProvider.session_history(ctx.fork_key, ctx.root)
      forked = Enum.map(entries, & &1.id)
      assert first_answer in forked
      refute alpha in forked
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
    start_supervised!(
      {Session,
       [
         cwd: ctx.root,
         model: model(),
         stream_fn: stream || echo_stream(self()),
         session_key: ctx.key,
         register: true,
         settings_manager: %{SettingsManager.load(ctx.root) | compaction_enabled: false}
       ]}
    )
  end

  defp start_resumed(ctx, path) do
    start_supervised!(
      {Session,
       [
         cwd: ctx.root,
         model: model(),
         stream_fn: echo_stream(self()),
         session_file: path,
         settings_manager: %{SettingsManager.load(ctx.root) | compaction_enabled: false}
       ]}
    )
  end

  defp prompt(session, text, opts \\ []) do
    flush_texts()
    assert :ok = Session.prompt(session, text)
    if Keyword.get(opts, :wait, true), do: wait_idle(session)
  end

  defp wait_idle(session) do
    wait_until(fn ->
      state = Session.get_state(session)
      leaf = SessionManager.get_entry(state.session_manager, state.session_manager.leaf_id)

      not state.is_streaming and leaf != nil and leaf.type == :message and
        message_role(leaf.message) == "assistant"
    end)
  end

  defp wait_until(fun, attempts \\ 500) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("timed out")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
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

  # The provider can be reached before the session persists the prompt.
  defp entry_id(session, role, text) do
    wait_until(fn -> find_entry(session, role, text) != nil end)
    find_entry(session, role, text).id
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
