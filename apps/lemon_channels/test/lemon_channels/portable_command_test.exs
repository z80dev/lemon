defmodule LemonChannels.PortableCommandTest do
  use ExUnit.Case, async: false

  alias LemonChannels.PortableCommand

  defmodule FakeRuntime do
    def list_tasks do
      [
        {"task-1234567890",
         %{status: :running, description: "Inspect command routing", updated_at: 9}},
        {"task-old", %{status: :completed, description: "Finished", updated_at: 1}}
      ]
    end

    def compact_session("session-ok", []), do: :ok
    def compact_session(_, []), do: {:error, :session_not_found}

    def background_start("index the repository", opts) do
      send(self(), {:background_start, opts})
      {:ok, %{id: "bg_1234567890abcdef", status: :queued}}
    end

    def side_query("session-ok", "what changed?", opts) do
      send(self(), {:side_query, opts})
      {:ok, "Only the portable command boundary changed."}
    end
  end

  setup do
    previous = Application.get_env(:lemon_control_plane, :agent_runtime_provider)
    Application.put_env(:lemon_control_plane, :agent_runtime_provider, FakeRuntime)

    on_exit(fn ->
      if previous do
        Application.put_env(:lemon_control_plane, :agent_runtime_provider, previous)
      else
        Application.delete_env(:lemon_control_plane, :agent_runtime_provider)
      end
    end)
  end

  test "renders grouped help from the portable catalog" do
    assert {:ok, help} = PortableCommand.handle("commands", "", %{})
    assert help =~ "Information"
    assert help =~ "/queue <prompt> (/q)"
    assert help =~ "/btw <question>"
  end

  test "renders task records through the registered runtime provider" do
    assert {:ok, tasks} = PortableCommand.handle("agents", "", %{})
    assert tasks =~ "task-123456"
    assert tasks =~ "running"
    assert tasks =~ "Inspect command routing"
  end

  test "compacts only through the registered session runtime" do
    assert PortableCommand.handle("compress", "", %{session_key: "session-ok"}) ==
             {:ok, "Compacted the current Lemon session context."}

    assert {:error, message} =
             PortableCommand.handle("compact", "", %{session_key: "missing"})

    assert message =~ "not live"
  end

  test "rejects missing side-run prompts without invoking a runtime" do
    assert PortableCommand.handle("bg", "", %{}) == {:error, "Usage: /bg <prompt>"}
    assert PortableCommand.handle("btw", "", %{}) == {:error, "Usage: /btw <question>"}
  end

  test "starts background work through the registered runtime provider" do
    assert PortableCommand.handle("bg", "index the repository", %{
             session_key: "session-ok",
             cwd: "/tmp/project",
             model: "test-model",
             thinking_level: "high"
           }) == {:ok, "Background run started: bg_123456789"}

    assert_received {:background_start, opts}
    assert opts[:session_key] == "session-ok"
    assert opts[:cwd] == "/tmp/project"
    assert opts[:model] == "test-model"
    assert opts[:thinking_level] == "high"
  end

  test "answers side questions through the registered runtime provider" do
    assert PortableCommand.handle("btw", "what changed?", %{
             session_key: "session-ok",
             timeout_ms: 5_000
           }) == {:ok, "Only the portable command boundary changed."}

    assert_received {:side_query, [timeout_ms: 5_000]}
  end
end
