defmodule LemonBrowser.NativeProcessTest do
  use ExUnit.Case, async: false

  alias LemonCore.NativeProcess

  @moduletag :tmp_dir

  defmodule FailingBackend do
    @behaviour LemonBrowser.Backend

    def id, do: :native_process_test
    def available?, do: true
    def available?(opts), do: Keyword.get(opts, :available, true)
    def status(_opts), do: %{available: true}

    def request(_method, _args, _timeout, opts) do
      send(Keyword.fetch!(opts, :owner), {:dispatched, NativeProcess.snapshot()})
      {:error, :partial_launch_failure}
    end
  end

  setup %{tmp_dir: dir} do
    previous = Application.fetch_env(:lemon_core, :native_process_ledger)
    :ok = NativeProcess.configure!(Path.join(dir, "native.dets"))
    ledger = Process.whereis(NativeProcess)
    :ok = LemonBrowser.BackendRegistry.register(:native_process_test, FailingBackend)

    on_exit(fn ->
      LemonBrowser.BackendRegistry.unregister(:native_process_test)
      if Process.alive?(ledger), do: GenServer.stop(ledger)

      case previous do
        {:ok, value} -> Application.put_env(:lemon_core, :native_process_ledger, value)
        :error -> Application.delete_env(:lemon_core, :native_process_ledger)
      end
    end)

    :ok
  end

  test "authorization, unknown backend and unavailable backend refuse before dispatch" do
    assert {:error, :browser_developer_mode_required} =
             LemonBrowser.request("browser.cdp", %{}, 500, backend: :native_process_test)

    assert {:error, {:unknown_browser_backend, :not_registered}} =
             LemonBrowser.request("browser.tabs", %{}, 500, backend: :not_registered)

    assert {:error, :browser_backend_unavailable} =
             LemonBrowser.request("browser.tabs", %{}, 500,
               backend: :native_process_test,
               available: false,
               owner: self()
             )

    assert NativeProcess.snapshot() == []
    refute_receive {:dispatched, _}
  end

  test "records uncertainty before backend dispatch and retains it after an error" do
    assert {:error, :partial_launch_failure} =
             LemonBrowser.request("browser.tabs", %{}, 500,
               backend: :native_process_test,
               owner: self()
             )

    assert_receive {:dispatched, [{_, %{backend: :unsupported, capacity_held: true}, %{}}]}
    assert [{_, %{backend: :unsupported, capacity_held: true}, %{}}] = NativeProcess.snapshot()
  end
end
