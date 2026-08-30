defmodule CodingAgent.Search.DispatcherTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Search.Dispatcher
  alias CodingAgent.Search.Registry

  defmodule UnavailableProvider do
    @behaviour CodingAgent.Search.Provider
    def id, do: "unavailable"
    def capabilities, do: [:search]
    def available?(:search, _context), do: {:error, :missing_key}
    def search(_request, _context), do: raise("should not run")
  end

  defmodule SuccessfulProvider do
    @behaviour CodingAgent.Search.Provider
    def id, do: "successful"
    def capabilities, do: [:search]
    def available?(:search, _context), do: :ok

    def search(request, context),
      do: {:ok, %{"query" => request.query, "marker" => context.marker}}
  end

  defmodule SlowProvider do
    @behaviour CodingAgent.Search.Provider
    def id, do: "slow"
    def capabilities, do: [:search]
    def available?(:search, _context), do: :ok

    def search(_request, _context) do
      Process.sleep(500)
      {:ok, %{}}
    end
  end

  setup do
    Registry.reset()
    :ok = Registry.register("unavailable", UnavailableProvider)
    :ok = Registry.register("successful", SuccessfulProvider)
    :ok = Registry.register("slow", SlowProvider)
    on_exit(&Registry.reset/0)
    :ok
  end

  test "falls back deterministically and reports attempts" do
    assert {:ok, payload, metadata} =
             Dispatcher.run(:search, %{query: "lemon"},
               providers: ["unavailable", "successful"],
               provider_contexts: %{"successful" => %{marker: "proof"}}
             )

    assert payload == %{"query" => "lemon", "marker" => "proof"}
    assert metadata.requested_provider == "unavailable"
    assert metadata.provider_used == "successful"

    assert metadata.attempts == [
             %{provider: "unavailable", status: :error, reason: {:unavailable, :missing_key}},
             %{provider: "successful", status: :ok}
           ]
  end

  test "isolates provider timeout and continues fallback" do
    assert {:ok, _payload, metadata} =
             Dispatcher.run(:search, %{query: "timeout"},
               providers: ["slow", "successful"],
               context: %{marker: "after-timeout"},
               timeout_ms: 10
             )

    assert metadata.provider_used == "successful"
    assert hd(metadata.attempts).reason == :provider_timeout
  end

  test "returns bounded structured errors when all providers fail" do
    assert {:error, {:all_providers_failed, attempts}} =
             Dispatcher.run(:search, %{query: "none"}, providers: ["missing", "unavailable"])

    assert Enum.map(attempts, & &1.provider) == ["missing", "unavailable"]
  end
end
