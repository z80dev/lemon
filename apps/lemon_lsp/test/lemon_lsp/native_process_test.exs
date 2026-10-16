defmodule LemonLsp.NativeProcessTest do
  use ExUnit.Case, async: false

  alias LemonCore.{NativeProcess, ProcessGroup}
  alias LemonLsp.ServerManager

  @moduletag :tmp_dir
  @command_env "LEMON_LSP_ELIXIR_LS_COMMAND"

  test "configured local servers retain a birth-bound native group witness", %{tmp_dir: dir} do
    previous_ledger = Application.fetch_env(:lemon_core, :native_process_ledger)
    previous_command = System.get_env(@command_env)
    session_id = "native-lsp-#{System.unique_integer([:positive])}"
    :ok = NativeProcess.configure!(Path.join(dir, "native.dets"))
    ledger = Process.whereis(NativeProcess)

    on_exit(fn ->
      ServerManager.stop_session(session_id)
      if Process.alive?(ledger), do: GenServer.stop(ledger)

      case previous_ledger do
        {:ok, value} -> Application.put_env(:lemon_core, :native_process_ledger, value)
        :error -> Application.delete_env(:lemon_core, :native_process_ledger)
      end

      if previous_command,
        do: System.put_env(@command_env, previous_command),
        else: System.delete_env(@command_env)
    end)

    System.put_env(@command_env, System.find_executable("cat"))
    assert {:ok, _} = ServerManager.start_session(:elixir_ls, cwd: dir, session_id: session_id)
    assert [{_, %{backend: :local, workload_identity: identity}, _}] = NativeProcess.snapshot()
    assert ProcessGroup.valid_identity?(identity)
    assert {:ok, %{status: :stopped}} = ServerManager.stop_session(session_id)
  end
end
