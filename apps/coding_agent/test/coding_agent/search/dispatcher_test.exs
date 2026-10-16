defmodule CodingAgent.Search.DispatcherTest do
  use ExUnit.Case, async: false

  import CodingAgent.AsyncHelpers

  alias CodingAgent.Search.Dispatcher
  alias CodingAgent.Search.Registry
  alias CodingAgent.Search.SingleFlight
  alias LemonAgent.AbortSignal

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
      Process.sleep(10_000)
      {:ok, %{}}
    end
  end

  defmodule BlockingProvider do
    @behaviour CodingAgent.Search.Provider
    def id, do: "blocking"
    def capabilities, do: [:search, :extract]

    def available?(capability, context) do
      send(context.test_pid, {:provider_available, capability, context.abort_signal})

      if Map.get(context, :abort_during_availability, false),
        do: LemonAgent.AbortSignal.abort(context.abort_signal)

      :ok
    end

    def search(_request, context), do: block(:search, context)
    def extract(_request, context), do: block(:extract, context)

    defp block(capability, context) do
      Process.flag(:trap_exit, true)
      send(context.test_pid, {:provider_started, capability, self(), context.abort_signal})

      receive do
        {:finish, result} ->
          result

        {:abort_and_finish, result} ->
          LemonAgent.AbortSignal.abort(context.abort_signal)
          result
      end
    end
  end

  defmodule RecordingProvider do
    @behaviour CodingAgent.Search.Provider
    def id, do: "recording"
    def capabilities, do: [:search, :extract]

    def available?(capability, context) do
      send(context.test_pid, {:fallback_available, capability})
      :ok
    end

    def search(_request, context), do: record(:search, context)
    def extract(_request, context), do: record(:extract, context)

    defp record(capability, context) do
      send(context.test_pid, {:fallback_started, capability})
      {:ok, %{"fallback" => true}}
    end
  end

  setup do
    Registry.reset()
    :ok = Registry.register("unavailable", UnavailableProvider)
    :ok = Registry.register("successful", SuccessfulProvider)
    :ok = Registry.register("slow", SlowProvider)
    :ok = Registry.register("blocking", BlockingProvider, config: %{abort_signal: make_ref()})
    :ok = Registry.register("recording", RecordingProvider)
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

  test "an already aborted signal prevents every provider attempt" do
    signal = new_signal()
    AbortSignal.abort(signal)

    for capability <- [:search, :extract] do
      assert Dispatcher.run(capability, %{},
               providers: ["blocking", "recording"],
               context: %{test_pid: self()},
               signal: signal
             ) == {:error, "Operation aborted"}
    end

    refute_received {:provider_available, _, _}
    refute_received {:provider_started, _, _, _}
    refute_received {:fallback_available, _}
    refute_received {:fallback_started, _}
  end

  test "blocked search and extraction are stopped before returning abort without fallback" do
    for capability <- [:search, :extract] do
      signal = new_signal()

      task =
        start_dispatch(capability, signal,
          context: %{test_pid: self(), abort_signal: make_ref()},
          provider_contexts: %{"blocking" => %{abort_signal: make_ref()}}
        )

      {provider, ^signal} = await_provider(capability)
      monitor = Process.monitor(provider)
      AbortSignal.abort(signal)

      assert Task.await(task, 5_000) == {:error, "Operation aborted"}
      refute Process.alive?(provider)
      assert_receive {:DOWN, ^monitor, :process, ^provider, :killed}, 5_000
      refute_received {:fallback_available, _}
      refute_received {:fallback_started, _}
    end
  end

  test "abort during availability prevents the callback and fallback" do
    signal = new_signal()

    assert Dispatcher.run(:extract, %{},
             providers: ["blocking", "recording"],
             context: %{test_pid: self(), abort_during_availability: true},
             signal: signal
           ) == {:error, "Operation aborted"}

    assert_received {:provider_available, :extract, ^signal}
    refute_received {:provider_started, _, _, _}
    refute_received {:fallback_available, _}
    refute_received {:fallback_started, _}
  end

  test "abort wins over a provider success or failure already being returned" do
    for result <- [{:ok, %{"late" => true}}, {:error, :retryable}, {:error, {:terminal, :stop}}] do
      signal = new_signal()
      task = start_dispatch(:extract, signal)
      {provider, ^signal} = await_provider(:extract)
      monitor = Process.monitor(provider)
      send(provider, {:abort_and_finish, result})

      assert Task.await(task, 5_000) == {:error, "Operation aborted"}
      refute Process.alive?(provider)
      assert_receive {:DOWN, ^monitor, :process, ^provider, _reason}, 5_000
      refute_received {:fallback_available, _}
      refute_received {:fallback_started, _}
    end
  end

  test "a provider abort result is not a retryable fallback error" do
    task = start_dispatch(:search, nil)
    {provider, nil} = await_provider(:search)
    send(provider, {:finish, {:error, "Operation aborted"}})

    assert Task.await(task, 5_000) == {:error, "Operation aborted"}
    refute Process.alive?(provider)
    refute_received {:fallback_available, _}
    refute_received {:fallback_started, _}
  end

  test "timeout confirms blocked provider cleanup before fallback succeeds" do
    task = start_dispatch(:extract, nil, timeout_ms: 100)
    {provider, nil} = await_provider(:extract)

    assert {:ok, %{"fallback" => true}, metadata} = Task.await(task, 5_000)
    refute Process.alive?(provider)
    assert metadata.provider_used == "recording"
    assert hd(metadata.attempts).reason == :provider_timeout
    assert_received {:fallback_available, :extract}
    assert_received {:fallback_started, :extract}
  end

  test "dispatcher death cannot orphan a callback that traps exits" do
    task = start_dispatch(:extract, nil)
    {provider, nil} = await_provider(:extract)
    provider_monitor = Process.monitor(provider)
    task_monitor = task.ref
    Process.unlink(task.pid)
    Process.exit(task.pid, :kill)

    assert_receive {:DOWN, ^task_monitor, :process, _, :killed}, 5_000
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :killed}, 5_000
    refute Process.alive?(provider)
    refute_received {:fallback_available, _}
    refute_received {:fallback_started, _}
  end

  test "single flight passes its shared signal and one aborted caller cannot stop another" do
    leaving = new_signal()
    staying = new_signal()
    key = make_ref()
    leaver = start_dispatch(:extract, leaving, single_flight_key: key)
    {provider, flight_signal} = await_provider(:extract)
    refute flight_signal == leaving
    stayer = start_dispatch(:extract, staying, single_flight_key: key)

    assert_eventually(
      fn ->
        case :sys.get_state(SingleFlight).by_key[{:extract, key}] do
          %{callers: callers} -> length(callers) == 2
          _ -> false
        end
      end,
      timeout: 5_000
    )

    AbortSignal.abort(leaving)
    assert Task.await(leaver, 5_000) == {:error, "Operation aborted"}
    refute AbortSignal.aborted?(flight_signal)
    assert Process.alive?(provider)
    send(provider, {:finish, {:ok, %{"shared" => true}}})

    assert {:ok, %{"shared" => true}, %{provider_used: "blocking"}} = Task.await(stayer, 5_000)
    refute Process.alive?(provider)
    refute_received {:fallback_available, _}
    refute_received {:fallback_started, _}
  end

  defp new_signal do
    signal = AbortSignal.new()
    on_exit(fn -> AbortSignal.clear(signal) end)
    signal
  end

  defp start_dispatch(capability, signal, opts \\ []) do
    opts =
      Keyword.merge(
        [
          providers: ["blocking", "recording"],
          signal: signal,
          context: %{test_pid: self()},
          timeout_ms: 15_000
        ],
        opts
      )

    task = Task.async(fn -> Dispatcher.run(capability, %{}, opts) end)
    stop_on_exit(task.pid)
    task
  end

  defp await_provider(capability) do
    assert_receive {:provider_available, ^capability, signal}, 5_000
    assert_receive {:provider_started, ^capability, provider, ^signal}, 5_000
    stop_on_exit(provider)
    {provider, signal}
  end

  defp stop_on_exit(pid) do
    on_exit(fn ->
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
    end)
  end
end
