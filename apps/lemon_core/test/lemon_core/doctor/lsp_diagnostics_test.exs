defmodule LemonCore.Doctor.LspDiagnosticsTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.LspDiagnostics

  test "returns redacted diagnostics capability status" do
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
    assert status.server_manager.supervised == true
    assert status.server_manager.running == true
    assert status.server_manager.mode == :registry_and_sessions
    assert is_list(status.server_manager.active_servers)
    assert is_list(status.server_manager.recent_sessions)
    assert status.server_manager.registry.count == 6
    assert status.server_manager.registry.cleanup.includes_executable_paths == false
  end
end
