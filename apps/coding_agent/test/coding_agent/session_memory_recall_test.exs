defmodule CodingAgent.SessionMemoryRecallTest do
  @moduledoc """
  Automatic recall end to end: a fact from one run reaches the model on a later
  run's opening message, through the real ingest path, the real store, and the
  real `LemonSkills.MemoryRecall` contributor — with no tool call in between.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Session
  alias LemonAgent.Test.Mocks
  alias LemonAi.Types.UserMessage

  setup do
    memory_store = Process.whereis(LemonMemory.Store)
    assert is_pid(memory_store), "durable memory store must be running"

    agent_id = "recall_e2e_#{System.unique_integer([:positive])}"
    cwd = tmp_cwd()
    workspace_dir = Path.join(cwd, "profile")
    Process.put(:recall_cwd, cwd)
    Process.put(:recall_workspace, workspace_dir)

    {:ok, identity} =
      LemonMemory.Project.scope(%{
        cwd: cwd,
        workspace_dir: workspace_dir,
        agent_id: agent_id,
        session_scope: :main
      })

    # Ingest resolves features independently of the session's project config.
    # Give this fixture its own worker with the same explicit project opt-in.
    ingest =
      start_supervised!(
        {LemonMemory.Ingest,
         name: __MODULE__.Ingest,
         memory_store: memory_store,
         config_loader: fn -> LemonCore.Config.Modular.load(project_dir: cwd) end}
      )

    # Run N: finished in another session and ingested like any finalized run.
    :ok =
      LemonMemory.Ingest.handle_finalize_run(ingest, %{
        run_id: "run-#{agent_id}",
        record: %{events: [], started_at: System.system_time(:millisecond)},
        summary: %{
          session_key: "agent:#{agent_id}:telegram:1",
          agent_id: agent_id,
          workspace_key: identity.root,
          meta: %{"home_digest" => identity.home_digest},
          prompt: "My sister Priya's birthday is on March 14th, please keep that in mind.",
          completed: %{ok: true, answer: "Noted: Priya's birthday is March 14th."}
        }
      })

    # The cast precedes this system call from the same sender. Once ingest has
    # drained, the store query observes its queued write without polling.
    _ = :sys.get_state(ingest)
    assert [_ | _] = LemonMemory.Store.search("priya", scope: :agent, scope_key: agent_id)

    %{agent_id: agent_id}
  end

  defp start_session(agent_id, cwd) do
    owner = self()
    inner = Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))

    stream_fn = fn model, context, options ->
      send(owner, {:sent, context.messages, context.system_prompt})
      inner.(model, context, options)
    end

    session =
      start_supervised!({
        Session,
        # Recall needs the project identity, not a capture session key.
        cwd: cwd,
        workspace_dir: Process.get(:recall_workspace),
        agent_id: agent_id,
        session_key: nil,
        model: Mocks.mock_model(),
        stream_fn: stream_fn
      })

    session
  end

  defp tmp_cwd do
    cwd = Path.join(System.tmp_dir!(), "memory_recall_e2e_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    File.mkdir_p!(Path.join(cwd, ".lemon"))

    File.write!(
      Path.join(cwd, ".lemon/config.toml"),
      "[features]\nsession_search = \"default-on\"\n"
    )

    on_exit(fn -> File.rm_rf(cwd) end)
    cwd
  end

  defp sent_user_text do
    assert_receive {:sent, messages, system_prompt}, 5_000

    %UserMessage{content: content} =
      messages |> Enum.filter(&match?(%UserMessage{}, &1)) |> List.last()

    text =
      if is_binary(content),
        do: content,
        else: Enum.map_join(content, "\n", &Map.get(&1, :text, ""))

    {text, system_prompt}
  end

  test "run N's fact is attached to run N+1's opening message", %{agent_id: agent_id} do
    session = start_session(agent_id, Process.get(:recall_cwd))

    :ok = Session.prompt(session, "What could I get Priya for her birthday?")
    {text, system_prompt} = sent_user_text()

    assert text =~ "Relevant memory"
    assert text =~ "March 14th"
    # Volatile recall rides the user message; the cached system prompt is untouched.
    refute system_prompt =~ "March 14th"
  end

  test "[memory] auto_recall = false attaches nothing", %{agent_id: agent_id} do
    cwd = Process.get(:recall_cwd)
    File.mkdir_p!(Path.join(cwd, ".lemon"))

    File.write!(
      Path.join([cwd, ".lemon", "config.toml"]),
      "[memory]\nauto_recall = false\n[features]\nsession_search = \"default-on\"\n"
    )

    session = start_session(agent_id, cwd)

    :ok = Session.prompt(session, "What could I get Priya for her birthday?")
    {text, _system_prompt} = sent_user_text()

    assert text == "What could I get Priya for her birthday?"
  end

  test "remembered USER.md facts accompany scoped recall without another tool call", %{
    agent_id: agent_id
  } do
    cwd = Process.get(:recall_cwd)
    workspace_dir = Process.get(:recall_workspace)
    fact = "Prefers handmade wooden birthday gifts."

    result =
      LemonSkills.Tools.Remember.tool(cwd, workspace_dir: workspace_dir, session_scope: :main).execute.(
        "remember-profile",
        %{"target" => "user", "text" => fact},
        nil,
        nil
      )

    assert result.details.changed
    session = start_session(agent_id, cwd)
    :ok = Session.prompt(session, "What could I get Priya for her birthday?")
    {text, _system_prompt} = sent_user_text()

    assert text =~ fact
    assert text =~ "March 14th"
  end
end
