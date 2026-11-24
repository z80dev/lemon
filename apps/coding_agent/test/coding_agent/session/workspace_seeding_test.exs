defmodule CodingAgent.Session.WorkspaceSeedingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodingAgent.Session
  alias LemonAi.Types.Model

  @moduletag :tmp_dir

  test "a bootstrap session seeds the workspace once and never re-creates deleted templates",
       %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")

    stop(start_session(tmp_dir, workspace, :chat))
    bootstrap = Path.join(workspace, "BOOTSTRAP.md")
    assert File.regular?(bootstrap)

    File.rm!(bootstrap)
    stop(start_session(tmp_dir, workspace, :chat))
    refute File.exists?(bootstrap)
  end

  test "coding sessions do not touch the assistant workspace", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")

    stop(start_session(tmp_dir, workspace, :coding))
    refute File.exists?(workspace)
  end

  test "session start against a read-only assistant home does not raise", %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "readonly-home")
    File.mkdir_p!(home)
    File.chmod!(home, 0o555)
    on_exit(fn -> File.chmod(home, 0o755) end)
    workspace = Path.join(home, "workspace")

    stop(start_session(tmp_dir, workspace, :coding))

    log = capture_log(fn -> stop(start_session(tmp_dir, workspace, :chat)) end)
    assert log =~ "Assistant workspace was not seeded"
    refute File.exists?(workspace)
  end

  defp start_session(cwd, workspace, mode) do
    opts = [
      cwd: cwd,
      workspace_dir: workspace,
      session_mode: mode,
      tools: [],
      extension_inventory: {[], []},
      mcp_tools: [],
      model: %Model{
        id: "mock-model-1",
        name: "Mock Model",
        api: :mock,
        provider: :mock_provider,
        base_url: "https://api.mock.test",
        reasoning: false,
        input: [:text],
        context_window: 128_000,
        max_tokens: 4096,
        headers: %{}
      },
      stream_fn: fn _model, _context, _options -> {:error, :unused} end
    ]

    start_supervised!(Supervisor.child_spec({Session, opts}, id: make_ref(), restart: :temporary))
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end
end
