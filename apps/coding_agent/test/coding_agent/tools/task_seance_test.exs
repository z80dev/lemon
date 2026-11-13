defmodule CodingAgent.Tools.TaskSeanceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session.BudgetLedger
  alias CodingAgent.SessionManager
  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.{Params, Seance}
  alias LemonAgent.Test.Mocks

  @key "agent:default:main"

  setup %{tmp_dir: tmp_dir} do
    previous = System.get_env("LEMON_AGENT_DIR")
    System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))
    cwd = Path.join(tmp_dir, "project")
    File.mkdir_p!(cwd)

    on_exit(fn ->
      if previous,
        do: System.put_env("LEMON_AGENT_DIR", previous),
        else: System.delete_env("LEMON_AGENT_DIR")
    end)

    %{cwd: cwd}
  end

  defp write_source(cwd, opts \\ []) do
    source = SessionManager.new(cwd)

    source =
      SessionManager.append_message(source, %{
        "role" => "user",
        "content" => "Old detail that compaction dropped."
      })

    source =
      SessionManager.append_message(source, %{
        "role" => "user",
        "content" => "We chose PostgreSQL because of JSONB."
      })

    kept_id = source.leaf_id

    source =
      SessionManager.append_compaction(source, "Summary: SQLite was rejected.", kept_id, 10)

    source = BudgetLedger.append(source, %{tokens: 900_000, cost_usd: 50})

    source =
      case Keyword.get(opts, :execution) do
        nil ->
          source

        execution ->
          {:ok, source} = SessionManager.append_execution_context(source, execution)
          source
      end

    path = SessionManager.session_file_path(cwd, source.header.id)
    :ok = SessionManager.save_to_file(path, source)
    {source.header.id, path}
  end

  # A caller whose journal descends from `parent` (its fork or task child).
  defp write_caller(cwd, parent) do
    caller = SessionManager.new(cwd, parent_session: parent)

    :ok =
      SessionManager.save_to_file(SessionManager.session_file_path(cwd, caller.header.id), caller)

    caller.header.id
  end

  defp execution(cwd, run_id) do
    {:ok, execution} =
      LemonCore.ExecutionContext.new(run_id: run_id, cwd: cwd, agent_id: "default")

    execution
  end

  defp keyed_source(cwd, key) do
    run_id = "seance-run-#{System.unique_integer([:positive])}"
    :ok = LemonCore.RunStore.finalize(run_id, %{session_key: key})
    write_source(cwd, execution: execution(cwd, run_id))
  end

  defp validate(cwd, params, opts) do
    Params.validate_run_params(Map.merge(%{"prompt" => "Recall"}, params), cwd, opts)
  end

  @tag :tmp_dir
  test "seance child sees the source transcript read-only and leaves it unchanged", %{cwd: cwd} do
    {id, path} = write_source(cwd)
    caller = write_caller(cwd, id)
    before = File.read!(path)
    owner = self()
    response = Mocks.mock_stream_fn_single(Mocks.assistant_message("PostgreSQL, for JSONB."))

    result =
      TaskTool.execute(
        "seance-call",
        %{
          "prompt" => "Which database was chosen and why?",
          "agent" => "seance",
          "source_session" => id,
          "async" => false,
          "auto_followup" => false
        },
        nil,
        nil,
        cwd,
        session_id: caller,
        session_key: @key,
        model: "openai-codex:gpt-6.1-sol",
        stream_fn: fn model, context, options ->
          send(owner, {:child_context, context})
          response.(model, context, options)
        end
      )

    assert result.details.status == "completed"
    assert_receive {:child_context, context}, 2_000

    history = inspect(context.messages)
    assert history =~ "We chose PostgreSQL because of JSONB."
    assert history =~ "Summary: SQLite was rejected."
    refute history =~ "Old detail that compaction dropped."
    assert history =~ "Which database was chosen and why?"

    names = Enum.map(context.tools, & &1.name)
    assert "read" in names
    assert Enum.all?(names, &(&1 in ~w(read grep find ls agent_message)))

    assert File.read!(path) == before
  end

  @tag :tmp_dir
  test "seance tools stay read-only even when a broader policy is requested", %{cwd: cwd} do
    {id, _path} = write_source(cwd)
    caller = write_caller(cwd, id)

    assert {:ok, validated} =
             validate(
               cwd,
               %{
                 "agent" => "seance",
                 "source_session" => id,
                 "tool_policy" => %{"allow" => "all"}
               },
               session_id: caller,
               session_key: @key
             )

    for tool <- ~w(write edit bash task) do
      refute CodingAgent.ToolPolicy.allowed?(validated.tool_policy, tool)
    end
  end

  @tag :tmp_dir
  test "only sessions of the caller's own conversation are in scope", %{cwd: cwd} do
    caller = write_caller(cwd, nil)
    caller_execution = execution(cwd, "seance-caller")
    scoped = [session_id: caller, session_key: @key, execution_context: caller_execution]

    {own, own_path} = keyed_source(cwd, @key)

    assert {:ok, %{source_session_file: ^own_path}} =
             validate(cwd, %{"agent" => "seance", "source_session" => own}, scoped)

    {foreign, _} = keyed_source(cwd, "agent:default:telegram:bot:dm:other-user")

    assert {:error, "source_session is not a session of the current conversation"} =
             validate(cwd, %{"agent" => "seance", "source_session" => foreign}, scoped)

    # An unrelated session without recorded ownership is not in scope either.
    {unbound, _} = write_source(cwd)

    assert {:error, _} =
             validate(cwd, %{"agent" => "seance", "source_session" => unbound}, scoped)

    assert {:error, "source_session requires a scoped caller session"} =
             validate(cwd, %{"agent" => "seance", "source_session" => own}, [])

    # A fenced caller may only consult its own lineage.
    fenced = Keyword.put(scoped, :workspace_read_fenced, true)
    assert {:error, _} = validate(cwd, %{"agent" => "seance", "source_session" => own}, fenced)

    {ancestor, _} = write_source(cwd)
    child = write_caller(cwd, ancestor)

    assert {:ok, _} =
             validate(
               cwd,
               %{"agent" => "seance", "source_session" => ancestor},
               Keyword.put(fenced, :session_id, child)
             )
  end

  @tag :tmp_dir
  test "missing, foreign and mismatched sources are refused before launch", %{
    cwd: cwd,
    tmp_dir: tmp_dir
  } do
    {id, path} = write_source(cwd)
    opts = [session_id: write_caller(cwd, id), session_key: @key]
    validate = &validate(cwd, &1, opts)

    assert {:error, msg} = validate.(%{"agent" => "seance", "source_session" => "nope"})
    assert msg =~ "not a session of the current project"

    other = Path.join(tmp_dir, "other")
    File.mkdir_p!(other)
    {_other_id, other_path} = write_source(other)
    assert {:error, _} = validate.(%{"agent" => "seance", "source_session" => other_path})

    copy = Path.join(tmp_dir, "copy.jsonl")
    File.cp!(path, copy)
    assert {:error, _} = validate.(%{"agent" => "seance", "source_session" => copy})

    renamed = Path.join(Path.dirname(path), "renamed.jsonl")
    File.cp!(path, renamed)
    assert {:error, _} = validate.(%{"agent" => "seance", "source_session" => renamed})

    assert {:error, msg} = validate.(%{"agent" => "seance"})
    assert msg =~ "source_session is required"
    assert {:error, _} = validate.(%{"agent" => "scout", "source_session" => id})

    assert {:error, _} =
             validate.(%{"agent" => "seance", "source_session" => id, "worktree" => true})

    assert {:ok, %{source_session_file: ^path}} =
             validate.(%{"agent" => "seance", "source_session" => path})
  end

  @tag :tmp_dir
  test "the fork starts a fresh spend ledger and is discarded when nothing ran", %{cwd: cwd} do
    {_id, path} = write_source(cwd)
    before = File.read!(path)

    assert {:ok, %{seance_session_file: fork} = validated} =
             Seance.fork(%{source_session_file: path}, session_id: "caller")

    {:ok, forked} = SessionManager.load_from_file(fork)
    assert BudgetLedger.restore(forked) == %{tokens: 0, cost_usd: 0}
    assert BudgetLedger.restore_children(forked) == %{tokens: 0, cost_usd: 0}
    assert forked.header.parent_session == "caller"

    assert :ok = Seance.discard_unused(validated)
    refute File.exists?(fork)
    assert File.read!(path) == before
  end
end
