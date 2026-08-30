defmodule LemonBrowser.HybridBackendTest do
  use ExUnit.Case, async: false

  alias LemonBrowser.BackendRegistry
  alias LemonBrowser.Backends.Hybrid

  defmodule LocalBackend do
    @behaviour LemonBrowser.Backend
    def id, do: :hybrid_local_test
    def available?, do: true
    def available?(_opts), do: true
    def status(_opts), do: %{available: true}

    def request(method, args, _timeout, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:local, method, args})
      {:ok, %{"backend" => "local", "method" => method}}
    end
  end

  defmodule PublicBackend do
    @behaviour LemonBrowser.Backend
    def id, do: :hybrid_public_test
    def available?, do: true
    def available?(_opts), do: true
    def status(_opts), do: %{available: true}

    def request(method, args, _timeout, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:public, method, args})

      if args["fail"] do
        {:error, :public_provider_failed}
      else
        {:ok, %{"backend" => "public", "method" => method}}
      end
    end
  end

  setup do
    :ok = BackendRegistry.register(:hybrid_local_test, LocalBackend)
    :ok = BackendRegistry.register(:hybrid_public_test, PublicBackend)

    on_exit(fn ->
      BackendRegistry.unregister(:hybrid_local_test)
      BackendRegistry.unregister(:hybrid_public_test)
    end)

    {:ok,
     opts: [
       session_id: "hybrid-session",
       run_id: "run-one",
       hybrid_local_backend: :hybrid_local_test,
       hybrid_public_backend: :hybrid_public_test,
       test_pid: self()
     ]}
  end

  test "requires explicit session and public backend configuration", %{opts: opts} do
    assert {:error, {:missing_hybrid_browser_binding, :session_id}} =
             Hybrid.request(
               "browser.navigate",
               %{"url" => "https://example.com"},
               500,
               Keyword.delete(opts, :session_id)
             )

    refute Hybrid.available?(Keyword.delete(opts, :hybrid_public_backend))
  end

  test "routes public targets to hosted and private targets to local", %{opts: opts} do
    assert {:ok, %{"backend" => "public"}} =
             Hybrid.request(
               "browser.navigate",
               %{"url" => "https://example.com"},
               500,
               opts
             )

    assert_received {:public, "browser.navigate", %{"url" => "https://example.com"}}

    assert {:ok, %{"backend" => "public"}} =
             Hybrid.request("browser.snapshot", %{}, 500, opts)

    assert_received {:public, "browser.snapshot", %{}}

    private_opts = Keyword.put(opts, :session_id, "private-session")

    assert {:ok, %{"backend" => "local"}} =
             Hybrid.request(
               "browser.navigate",
               %{"url" => "http://127.0.0.1:4000"},
               500,
               private_opts
             )

    assert_received {:local, "browser.navigate", %{"url" => "http://127.0.0.1:4000"}}

    assert {:ok, %{"backend" => "local"}} =
             Hybrid.request("browser.click", %{"selector" => "button"}, 500, private_opts)

    assert_received {:local, "browser.click", %{"selector" => "button"}}
  end

  test "sessions can switch routes only through explicit navigation", %{opts: opts} do
    assert {:error, :hybrid_browser_navigation_required} =
             Hybrid.request("browser.snapshot", %{}, 500, opts)

    assert {:ok, _} =
             Hybrid.request(
               "browser.navigate",
               %{"url" => "https://example.com"},
               500,
               opts
             )

    assert {:ok, %{"backend" => "local"}} =
             Hybrid.request(
               "browser.navigate",
               %{"url" => "file:///tmp/example.html"},
               500,
               opts
             )

    assert {:ok, %{"backend" => "local"}} =
             Hybrid.request("browser.snapshot", %{}, 500, opts)
  end

  test "a public provider failure never falls back to local", %{opts: opts} do
    assert {:error, :public_provider_failed} =
             Hybrid.request(
               "browser.navigate",
               %{"url" => "https://example.com", "fail" => true},
               500,
               opts
             )

    assert_received {:public, "browser.navigate", _}
    refute_received {:local, _, _}
  end

  test "metadata targets remain blocked before either backend", %{opts: opts} do
    assert {:error, reason} =
             Hybrid.request(
               "browser.navigate",
               %{"url" => "http://169.254.169.254/latest/meta-data"},
               500,
               opts
             )

    assert reason =~ "metadata"
    refute_received {:local, _, _}
    refute_received {:public, _, _}
  end
end
