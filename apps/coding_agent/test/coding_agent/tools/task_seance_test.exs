defmodule CodingAgent.Tools.TaskSeanceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SessionManager
  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.Params
  alias LemonAgent.Test.Mocks

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

  defp write_source(cwd) do
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

    path = SessionManager.session_file_path(cwd, source.header.id)
    :ok = SessionManager.save_to_file(path, source)
    {source.header.id, path}
  end

  @tag :tmp_dir
  test "seance child sees the source transcript read-only and leaves it unchanged", %{cwd: cwd} do
    {id, path} = write_source(cwd)
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
        parent_session: "seance-parent",
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

    assert {:ok, validated} =
             Params.validate_run_params(
               %{
                 "prompt" => "Recall",
                 "agent" => "seance",
                 "source_session" => id,
                 "tool_policy" => %{"allow" => "all"}
               },
               cwd
             )

    for tool <- ~w(write edit bash task) do
      refute CodingAgent.ToolPolicy.allowed?(validated.tool_policy, tool)
    end
  end

  @tag :tmp_dir
  test "missing, foreign and mismatched sources are refused before launch", %{
    cwd: cwd,
    tmp_dir: tmp_dir
  } do
    {id, path} = write_source(cwd)

    validate = fn params ->
      Params.validate_run_params(Map.merge(%{"prompt" => "Recall"}, params), cwd)
    end

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
end
