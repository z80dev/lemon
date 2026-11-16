defmodule LemonBrowser.BackendRegistryTest do
  use ExUnit.Case, async: false

  alias LemonBrowser.BackendRegistry

  defmodule TestBackend do
    @behaviour LemonBrowser.Backend

    def id, do: :test_browser_backend
    def available?, do: true

    def request(method, args, timeout_ms, opts) do
      {:ok, %{method: method, args: args, timeout_ms: timeout_ms, opts: opts}}
    end

    def status(_opts), do: %{running: true}
  end

  setup do
    BackendRegistry.reset()
    on_exit(&BackendRegistry.reset/0)
  end

  test "contended register and unregister fail without changing the registry" do
    assert :ok = BackendRegistry.register(:test_browser_backend, TestBackend)
    lock = {{BackendRegistry, :mutation}, self()}
    assert :global.set_lock(lock, [node()], 0)

    try do
      register =
        Task.async(fn -> BackendRegistry.register(:another_browser_backend, TestBackend) end)

      unregister = Task.async(fn -> BackendRegistry.unregister(:test_browser_backend) end)

      assert {:error, :registry_unavailable} = Task.await(register, 10_000)
      assert {:error, :registry_unavailable} = Task.await(unregister, 10_000)
      assert BackendRegistry.fetch(:another_browser_backend) == :error
      assert BackendRegistry.fetch(:test_browser_backend) == {:ok, TestBackend}
    after
      :global.del_lock(lock, [node()])
    end

    assert :ok = BackendRegistry.unregister(:test_browser_backend)
  end

  test "built-in local backend cannot be replaced" do
    assert {:ok, LemonBrowser.Backends.Local} = BackendRegistry.fetch(:local)
    assert {:error, :builtin_backend} = BackendRegistry.register(:local, TestBackend)
  end

  test "runtime backend registers, executes through the facade, and unregisters" do
    assert :ok = BackendRegistry.register(:test_browser_backend, TestBackend)

    assert {:ok, result} =
             LemonBrowser.request("browser.tabs", %{}, 123,
               backend: :test_browser_backend,
               marker: :ok
             )

    assert result.method == "browser.tabs"
    assert result.timeout_ms == 123
    assert result.opts[:marker] == :ok

    assert %{
             available: true,
             backend: :test_browser_backend,
             running: true,
             provider_resolution: %{requested: _, provider: _, reason: _}
           } = LemonBrowser.status(backend: :test_browser_backend)

    assert :ok = BackendRegistry.unregister(:test_browser_backend)

    assert {:error, {:unknown_browser_backend, :test_browser_backend}} =
             LemonBrowser.request("browser.tabs", %{}, 123, backend: :test_browser_backend)
  end

  test "invalid and unknown backends fail closed" do
    assert {:error, :invalid_backend} = BackendRegistry.register(:test_browser_backend, String)
    assert BackendRegistry.fetch("this-id-does-not-exist") == :error
  end
end
