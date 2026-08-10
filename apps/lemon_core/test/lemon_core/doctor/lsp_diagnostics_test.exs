defmodule LemonCore.Doctor.LspDiagnosticsTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.LspDiagnostics

  # The language-server runtime lives in lemon_lsp and reaches these
  # diagnostics through :doctor_runtime. lemon_lsp's own suite covers what
  # ServerManager.status/0 reports; here we cover the capability summary core
  # owns, plus both registration states.
  defmodule StubServerManager do
    def status do
      %{
        supervised: true,
        running: true,
        mode: :registry_and_sessions,
        active_servers: [],
        recent_sessions: [],
        registry: %{count: 6, cleanup: %{includes_executable_paths: false}}
      }
    end
  end

  defp put_runtime(value) do
    original = Application.get_env(:lemon_core, :doctor_runtime, [])

    Application.put_env(
      :lemon_core,
      :doctor_runtime,
      Keyword.put(original, :lsp_server_manager, value)
    )

    on_exit(fn -> Application.put_env(:lemon_core, :doctor_runtime, original) end)
  end

  test "returns redacted diagnostics capability status" do
    put_runtime(StubServerManager)
    status = LspDiagnostics.status()

    assert status.status == :preview
    assert status.default_timeout_ms == 20_000
    assert status.supported_language_count == length(status.supported_languages)
    assert Enum.any?(status.supported_languages, &(&1.language == :elixir))
    assert Enum.any?(status.supported_languages, &(&1.language == :typescript))
    assert Enum.any?(status.supported_languages, &(&1.language == :c_cpp))
    assert is_integer(status.executable_summary.available_count)
    assert is_list(status.executable_summary.executables)
    assert status.cleanup.includes_raw_paths == false
    assert status.cleanup.includes_file_contents == false
    assert status.cleanup.includes_diagnostics_output == false
    assert status.cleanup.includes_workspace_roots == false
    assert status.cleanup.includes_server_io == false
    assert status.cleanup.includes_raw_session_ids == false
  end

  test "passes the registered server manager's status through" do
    put_runtime(StubServerManager)
    status = LspDiagnostics.status()

    assert status.server_manager.supervised == true
    assert status.server_manager.running == true
    assert status.server_manager.mode == :registry_and_sessions
    assert is_list(status.server_manager.active_servers)
    assert is_list(status.server_manager.recent_sessions)
    assert status.server_manager.registry.count == 6
    assert status.server_manager.registry.cleanup.includes_executable_paths == false
  end

  test "falls back when no lsp runtime is registered" do
    put_runtime(nil)
    status = LspDiagnostics.status()

    assert status.status == :preview
    assert status.server_manager.supervised == false
    assert status.server_manager.running == false
    assert status.server_manager.mode == :unavailable
    assert status.server_manager.error == "lsp runtime not available"
  end
end
