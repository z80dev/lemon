defmodule LemonOmp.NativeProcessTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport
  alias LemonCore.{NativeProcess, ProcessGroup}

  @moduletag :tmp_dir

  test "local delegate ownership does not attest termination of delegate tools", %{tmp_dir: dir} do
    previous = Application.fetch_env(:lemon_core, :native_process_ledger)
    :ok = NativeProcess.configure!(Path.join(dir, "native.dets"))
    ledger = Process.whereis(NativeProcess)

    on_exit(fn ->
      close_all_sessions()
      if Process.alive?(ledger), do: GenServer.stop(ledger)

      case previous do
        {:ok, value} -> Application.put_env(:lemon_core, :native_process_ledger, value)
        :error -> Application.delete_env(:lemon_core, :native_process_ledger)
      end
    end)

    use_fake_omp()
    put_app_env(:session_dir, Path.join(dir, "sessions"))
    workspace = workspace!()

    assert {:error, :invalid_prompt} = LemonOmp.start(%{cwd: workspace})
    assert NativeProcess.snapshot() == []
    assert {:ok, wire} = LemonOmp.start(%{cwd: workspace, prompt: "offline test"})
    assert {:ok, _, :settled} = LemonOmp.wait(wire["id"], 10_000)

    rows = NativeProcess.snapshot()

    assert [{_, %{workload_identity: identity}, _}] =
             Enum.filter(rows, fn {_, record, _} -> record.backend == :local end)

    assert ProcessGroup.valid_identity?(identity)

    assert [{id, %{backend: :unsupported, capacity_held: true}, %{}}] =
             Enum.filter(rows, fn {_, record, _} -> record.backend == :unsupported end)

    assert {:ok, _} = LemonOmp.close(wire["id"])

    assert Enum.any?(NativeProcess.snapshot(), fn {row_id, record, _} ->
             row_id == id and record.capacity_held and not record.termination_confirmed
           end)
  end
end
