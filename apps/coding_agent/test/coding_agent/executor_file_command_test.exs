defmodule CodingAgent.ExecutorFileCommandTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Executor
  alias LemonAgent.Test.Mocks
  alias LemonAi.Types.{TextContent, UserMessage}
  alias LemonGateway.ExecutionRequest

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".claude/commands/git/review.md")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    ---
    description: Review a path
    ---
    Review $1 carefully. Notes: $ARGUMENTS
    """)

    :ok
  end

  test "a user prompt naming a file command reaches the model expanded", %{tmp_dir: tmp_dir} do
    assert last_user_text(tmp_dir, "/git:review lib/app.ex now", :control_plane) ==
             "Review lib/app.ex carefully. Notes: lib/app.ex now"

    assert last_user_text(tmp_dir, "/git:review lib/app.ex", :channel) ==
             "Review lib/app.ex carefully. Notes: lib/app.ex"
  end

  test "unknown commands and non-user origins pass through unchanged", %{tmp_dir: tmp_dir} do
    assert last_user_text(tmp_dir, "/unknown thing", :control_plane) == "/unknown thing"
    assert last_user_text(tmp_dir, "/git:review lib/app.ex", :node) == "/git:review lib/app.ex"
    assert last_user_text(tmp_dir, "/git:review lib/app.ex", :cron) == "/git:review lib/app.ex"
  end

  defp last_user_text(cwd, prompt, origin) do
    parent = self()
    stream = Mocks.mock_stream_fn([Mocks.assistant_message("done")])

    stream_fn = fn model, context, options ->
      send(parent, {:context_messages, context.messages})
      stream.(model, context, options)
    end

    request = %ExecutionRequest{
      run_id: "run-file-command-#{System.unique_integer([:positive])}",
      session_key: "test:lemon:#{System.unique_integer([:positive])}",
      prompt: prompt,
      images: [],
      cwd: cwd,
      meta: %{model: Mocks.mock_model(), origin: origin}
    }

    {:ok, run_ref, _ctx} = Executor.start_run(request, %{stream_fn: stream_fn}, self())
    assert_receive {:context_messages, messages}, 5_000
    assert_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 5_000

    %UserMessage{content: content} =
      messages |> Enum.filter(&match?(%UserMessage{}, &1)) |> List.last()

    text =
      case content do
        text when is_binary(text) -> text
        blocks -> Enum.map_join(blocks, "", fn %TextContent{text: text} -> text end)
      end

    # Automatic recall may append its fenced volatile block after the user text.
    text |> String.split("\n\n<recalled-context>") |> hd()
  end
end
