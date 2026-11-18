defmodule CodingAgent.Tools.TaskPersonaInheritanceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session
  alias CodingAgent.Tools.Task, as: TaskTool
  alias LemonAgent.Test.Mocks

  @moduletag :tmp_dir

  for persona <- [false, true] do
    test "a chat parent with persona: #{persona} passes it to its delegated child", %{
      tmp_dir: tmp_dir
    } do
      persona = unquote(persona)
      cwd = Path.join(tmp_dir, "project")
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(cwd)
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "home-agents-marker")

      parent =
        start_supervised!(
          {Session,
           cwd: cwd,
           workspace_dir: workspace,
           session_mode: :chat,
           persona: persona,
           tools: [],
           extension_inventory: {[], []},
           mcp_tools: [],
           model: Mocks.mock_model(),
           stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))}
        )

      parent_state = Session.get_state(parent)
      assert parent_state.tool_opts[:persona] == persona
      assert parent_state.system_prompt =~ "home-agents-marker" == persona

      owner = self()
      response = Mocks.mock_stream_fn_single(Mocks.assistant_message("child done"))

      opts =
        Keyword.put(parent_state.tool_opts, :stream_fn, fn model, context, options ->
          send(owner, {:child_context, context})
          response.(model, context, options)
        end)

      result =
        TaskTool.execute(
          "persona-#{System.unique_integer([:positive])}",
          %{"prompt" => "Say hi.", "async" => false, "auto_followup" => false},
          nil,
          nil,
          cwd,
          opts
        )

      assert result.details.status == "completed"
      assert_receive {:child_context, context}, 5_000
      child_prompt = LemonAi.SystemPrompt.text(context.system_prompt)
      assert child_prompt =~ "home-agents-marker" == persona
    end
  end
end
