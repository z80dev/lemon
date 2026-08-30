defmodule LemonChannels.PortableCommandTest do
  use ExUnit.Case, async: false

  alias LemonChannels.PortableCommand

  defmodule PortableCommandFakeRuntime do
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

    def background_start("leak", _opts),
      do: {:error, {:provider_error, "secret-token /private/project"}}

    def background_list_scoped("session-ok", []) do
      [
        %{id: "bg_1234567890abcdef", status: :running, result_available: false},
        %{id: "bg_done", status: :completed, result_available: true}
      ]
    end

    def background_list_scoped(_, []), do: []

    def background_status_scoped("bg_1234567890abcdef", "session-ok") do
      {:ok, %{id: "bg_1234567890abcdef", status: :running, result_available: false}}
    end

    def background_status_scoped(_, _), do: {:error, :not_found}

    def background_result_scoped("bg_1234567890abcdef", "session-ok"),
      do: {:error, :not_ready}

    def background_result_scoped("bg_done", "session-ok"), do: {:ok, "All checks passed."}

    def background_result_scoped("bg_secret", "session-ok"),
      do: {:error, {:failed, "secret-token /private/project"}}

    def background_result_scoped(_, _), do: {:error, :not_found}

    def background_cancel_scoped("bg_1234567890abcdef", "session-ok") do
      send(self(), :background_cancelled)
      :ok
    end

    def background_cancel_scoped(_, _), do: {:error, :not_found}

    def side_query("session-ok", "what changed?", opts) do
      send(self(), {:side_query, opts})
      {:ok, "Only the portable command boundary changed."}
    end

    def side_query("session-ok", "leak", _opts),
      do: {:error, {:provider_error, "secret-token /private/project"}}
  end

  setup do
    previous = Application.get_env(:lemon_control_plane, :agent_runtime_provider)

    Application.put_env(
      :lemon_control_plane,
      :agent_runtime_provider,
      PortableCommandFakeRuntime
    )

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
    assert {:error, bg_usage} = PortableCommand.handle("bg", "", %{})
    assert bg_usage =~ "Usage: /bg <prompt>"
    assert bg_usage =~ "/bg result <id>"
    assert PortableCommand.handle("btw", "", %{}) == {:error, "Usage: /btw <question>"}
  end

  test "starts background work through the registered runtime provider" do
    assert PortableCommand.handle("bg", "index the repository", %{
             session_key: "session-ok",
             cwd: "/tmp/project",
             model: "test-model",
             thinking_level: "high"
           }) ==
             {:ok,
              "Background run started: bg_1234567890abcdef\n" <>
                "Use /bg status bg_1234567890abcdef, /bg result bg_1234567890abcdef, or /bg cancel bg_1234567890abcdef."}

    assert_received {:background_start, opts}
    assert opts[:session_key] == "session-ok"
    assert opts[:cwd] == "/tmp/project"
    assert opts[:model] == "test-model"
    assert opts[:thinking_level] == "high"
  end

  test "exposes the durable background lifecycle with full ids" do
    context = %{session_key: "session-ok"}
    assert {:ok, listed} = PortableCommand.handle("bg", "list", context)
    assert listed =~ "bg_1234567890abcdef — running"
    assert listed =~ "bg_done — completed"

    assert PortableCommand.handle("bg", "status bg_1234567890abcdef", context) ==
             {:ok, "Background run bg_1234567890abcdef\nStatus: running\nResult: not available"}

    assert PortableCommand.handle("bg", "result bg_1234567890abcdef", context) ==
             {:ok, "Background run bg_1234567890abcdef is not finished yet."}

    assert PortableCommand.handle("bg", "result bg_done", context) ==
             {:ok, "Background result bg_done\nAll checks passed."}

    assert PortableCommand.handle("bg", "cancel bg_1234567890abcdef", context) ==
             {:ok, "Cancelled background run bg_1234567890abcdef."}

    assert_received :background_cancelled
  end

  test "background lifecycle is isolated between channel session principals" do
    foreign_context = %{session_key: "session-other"}

    assert PortableCommand.handle("bg", "list", foreign_context) ==
             {:ok, "No background runs are recorded."}

    for action <- ["status", "result", "cancel"] do
      assert PortableCommand.handle(
               "bg",
               "#{action} bg_1234567890abcdef",
               foreign_context
             ) == {:error, "Background run not found."}
    end

    refute_received :background_cancelled
  end

  test "redacts arbitrary runtime failure terms from channel responses" do
    for response <- [
          PortableCommand.handle("bg", "leak", %{}),
          PortableCommand.handle("bg", "result bg_secret", %{session_key: "session-ok"}),
          PortableCommand.handle("btw", "leak", %{session_key: "session-ok"})
        ] do
      assert {:error, message} = response
      refute message =~ "secret-token"
      refute message =~ "/private/project"
      refute message =~ "provider_error"
    end
  end

  test "answers side questions through the registered runtime provider" do
    assert PortableCommand.handle("btw", "what changed?", %{
             session_key: "session-ok",
             timeout_ms: 5_000
           }) == {:ok, "Only the portable command boundary changed."}

    assert_received {:side_query, [timeout_ms: 5_000]}
  end
end
