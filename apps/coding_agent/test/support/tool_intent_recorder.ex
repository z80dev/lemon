defmodule CodingAgent.Test.ToolIntentRecorder do
  @moduledoc false

  alias CodingAgent.SessionManager

  # Build in the test process, then pass the callback to workers as needed.
  # Each invocation owns a real raw append handle; files stay durable until
  # test teardown, outside the workspace being asserted on.
  def new(cwd) do
    scratch =
      Path.join(System.tmp_dir!(), "lemon-tool-intent-test-#{System.unique_integer([:positive])}")

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(scratch) end)

    fn data ->
      path = Path.join(scratch, "#{System.unique_integer([:positive])}.jsonl")
      session = SessionManager.new(cwd) |> SessionManager.persist(path)

      try do
        case SessionManager.record_tool_intent(session, data) do
          {:ok, _session} -> :ok
          {:error, reason, _session} -> {:error, reason}
        end
      after
        SessionManager.close(session)
      end
    end
  end
end
