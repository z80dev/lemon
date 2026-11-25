defmodule CodingAgent.FollowupMergeExecutorTest do
  @moduledoc """
  Two follow-ups merged inside the router's debounce window must still start in
  the native executor: the survivor's execution context belongs to its own run.
  Both submissions come from the real `LemonRouter.SubmissionBuilder`.
  """
  use ExUnit.Case, async: false

  alias LemonAi.Types.{AssistantMessage, TextContent}
  alias LemonRouter.{SessionState, SessionTransitions, SubmissionBuilder}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    global = Path.join(tmp, "home/.lemon/config.toml")
    project = Path.join(tmp, "project")
    File.mkdir_p!(Path.dirname(global))
    File.mkdir_p!(project)

    File.write!(global, """
    [defaults]
    provider = "openai"
    model = "openai:gpt-4o-mini"

    [providers.openai]
    api_key = "operator-openai-key"
    """)

    saved_paths = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, global_config: global)
    LemonCore.ConfigCache.invalidate(project)

    on_exit(fn ->
      if saved_paths,
        do: Application.put_env(:lemon_core, :paths, saved_paths),
        else: Application.delete_env(:lemon_core, :paths)

      LemonCore.ConfigCache.invalidate(project)
    end)

    %{project: project}
  end

  test "a debounce-merged followup starts with both messages in order", %{project: project} do
    session_key = "agent:default:followup-merge:#{System.unique_integer([:positive])}"
    previous = build(session_key, project, "First message")
    current = build(session_key, project, "Second message")

    state = %SessionState{
      conversation_key: current.conversation_key,
      queue: [previous],
      last_followup_at_ms: 100
    }

    assert {:ok, next, [:maybe_start_next]} = SessionTransitions.submit(state, current, 200)
    assert [merged] = next.queue
    command = merged.execution_request
    assert command.run_id == current.run_id
    assert command.execution_context.run_id == current.run_id

    parent = self()

    stream_fn = fn model, context, _options ->
      send(parent, {:provider_call, context.messages})

      response = %AssistantMessage{
        content: [%TextContent{text: "done"}],
        stop_reason: :stop,
        model: model.id,
        provider: model.provider
      }

      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.push(stream, {:start, response})
      LemonAi.EventStream.push(stream, {:done, :stop, response})
      LemonAi.EventStream.complete(stream, response)
      {:ok, stream}
    end

    assert {:ok, _run_ref, %{runner_pid: runner}} =
             command
             |> LemonGateway.ExecutionRequest.from_command()
             |> CodingAgent.Executor.start_run(%{stream_fn: stream_fn}, self())

    on_exit(fn -> CodingAgent.Session.Presentation.safe_stop_session(runner) end)

    assert_receive {:provider_call, messages}, 10_000
    prompt = messages |> List.last() |> user_text()
    assert prompt =~ ~r/First message\nSecond message/
  end

  defp build(session_key, cwd, prompt) do
    request =
      LemonCore.RunRequest.new(%{
        origin: :control_plane,
        session_key: session_key,
        agent_id: "default",
        prompt: prompt,
        cwd: cwd,
        queue_mode: :followup,
        run_id: "run_#{System.unique_integer([:positive])}"
      })

    assert {:ok, submission} =
             SubmissionBuilder.build(request, %{
               run_supervisor: LemonRouter.RunSupervisor,
               run_process_module: LemonRouter.RunProcess,
               run_process_opts: %{}
             })

    submission
  end

  defp user_text(%{content: content}) when is_binary(content), do: content

  defp user_text(%{content: content}) when is_list(content) do
    Enum.map_join(content, "", fn
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end)
  end
end
