defmodule LemonChannels.AdapterSupervisionTest do
  @moduledoc """
  Configured adapters survive an `AdapterSupervisor` restart, a crash-looping
  adapter cannot empty the supervisor, and a held Telegram poller lock leaves
  Telegram waiting alive instead of crashing.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonChannels.Application, as: ChannelsApp

  defmodule StubWorker do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)

    @impl true
    def init(:ok), do: {:ok, :ok}
  end

  defmodule Crasher do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid) do
      send(test_pid, {:crasher_started, self()})
      send(self(), :crash)
      {:ok, test_pid}
    end

    @impl true
    def handle_info(:crash, _state), do: raise("stub adapter crash loop")
  end

  for {mod, id} <- [
        {DiscordStub, "sup-test-discord"},
        {XmtpStub, "sup-test-xmtp"},
        {EmailStub, "sup-test-email"}
      ] do
    defmodule mod do
      @behaviour LemonChannels.Plugin
      @id id
      @impl true
      def id, do: @id
      @impl true
      def meta, do: %{label: @id, capabilities: %{}, docs: nil}
      @impl true
      def child_spec(_opts),
        do: %{
          id: __MODULE__,
          start: {StubWorker, :start_link, [Module.concat(__MODULE__, Worker)]}
        }

      @impl true
      def normalize_inbound(_raw), do: {:error, :not_implemented}
      @impl true
      def deliver(_payload), do: {:error, :not_implemented}
      @impl true
      def gateway_methods, do: []
    end
  end

  defmodule CrashLoopAdapter do
    @behaviour LemonChannels.Plugin
    @impl true
    def id, do: "sup-test-crash-loop"
    @impl true
    def meta, do: %{label: "crash", capabilities: %{}, docs: nil}
    @impl true
    def child_spec(opts),
      do: %{id: __MODULE__, start: {Crasher, :start_link, [Keyword.get(opts, :test_pid)]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_implemented}
    @impl true
    def deliver(_payload), do: {:error, :not_implemented}
    @impl true
    def gateway_methods, do: []
  end

  defmodule LockAPI do
    def get_updates(_token, _offset, _timeout_ms) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil), do: send(pid, :telegram_polled)
      {:ok, %{"ok" => true, "result" => []}}
    end

    def set_my_commands(_token, _commands), do: {:ok, %{"ok" => true}}
    def delete_webhook(_token, _opts \\ %{}), do: {:ok, %{"ok" => true}}
  end

  @stubs [DiscordStub, XmtpStub, EmailStub]

  setup do
    old_adapters = Application.get_env(:lemon_channels, :adapters)
    old_backoff = Application.get_env(:lemon_channels, :adapter_restart_backoff)

    Application.put_env(:lemon_channels, :adapter_restart_backoff,
      base_backoff_ms: 5,
      max_backoff_ms: 20
    )

    on_exit(fn ->
      restore_env(:adapters, old_adapters)
      restore_env(:adapter_restart_backoff, old_backoff)
      :persistent_term.erase({LockAPI, :pid})

      for mod <- @stubs ++ [CrashLoopAdapter, LemonChannels.Adapters.Telegram] do
        _ = ChannelsApp.stop_adapter(mod)
        LemonChannels.Registry.unregister(mod.id())
      end
    end)

    :ok
  end

  test "killing AdapterSupervisor restarts every configured adapter" do
    Application.put_env(:lemon_channels, :adapters, @stubs)
    Enum.each(@stubs, &(:ok = ChannelsApp.register_and_start_adapter(&1)))
    before = Enum.map(@stubs, &worker_pid/1)
    assert Enum.all?(before, &is_pid/1)

    old_sup = Process.whereis(LemonChannels.AdapterSupervisor)
    ref = Process.monitor(old_sup)
    Process.exit(old_sup, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_sup, :killed}

    after_restart =
      wait_until(fn ->
        pids = all_pids(@stubs)
        pids && Enum.all?(Enum.zip(before, pids), fn {a, b} -> a != b end) && pids
      end)

    assert length(after_restart) == 3
    assert Process.whereis(LemonChannels.AdapterSupervisor) != old_sup

    for mod <- @stubs, do: assert(LemonChannels.Registry.get_plugin(mod.id()) == mod)
  end

  test "a crash-looping adapter never empties the supervisor" do
    Enum.each(@stubs, &(:ok = ChannelsApp.register_and_start_adapter(&1)))
    sup = Process.whereis(LemonChannels.AdapterSupervisor)
    stub_pids = Enum.map(@stubs, &worker_pid/1)

    capture_log(fn ->
      :ok = ChannelsApp.register_and_start_adapter(CrashLoopAdapter, test_pid: self())
      # Far more crashes than any supervisor's default 3-in-5s intensity.
      for _ <- 1..8, do: assert_receive({:crasher_started, _}, 2_000)
    end)

    assert Process.whereis(LemonChannels.AdapterSupervisor) == sup
    assert Enum.map(@stubs, &worker_pid/1) == stub_pids
  end

  test "a held Telegram poller lock leaves Telegram retrying and other adapters registered" do
    token = "sup-lock-#{System.unique_integer([:positive])}"
    :persistent_term.put({LockAPI, :pid}, self())
    Enum.each(@stubs, &(:ok = ChannelsApp.register_and_start_adapter(&1)))

    # Another runtime holds the token-scoped poller lock.
    holder = spawn(fn -> Process.sleep(:infinity) end)

    lock =
      {LemonChannels.Telegram.PollerLock,
       "telegram-poller-" <> Base.encode16(:crypto.hash(:sha256, token), case: :lower)}

    :yes = :global.register_name(lock, holder)

    log =
      capture_log(fn ->
        assert :ok =
                 ChannelsApp.register_and_start_adapter(LemonChannels.Adapters.Telegram,
                   config: %{
                     bot_token: token,
                     api_mod: LockAPI,
                     bot_id: 1,
                     bot_username: "lock_bot",
                     poll_interval_ms: 60_000,
                     poller_lock_retry_ms: 20
                   }
                 )

        transport =
          wait_until(fn -> Process.whereis(LemonChannels.Adapters.Telegram.Transport) end)

        wait_until(fn -> :sys.get_state(transport)[:attempt] >= 2 end)
        assert Process.whereis(LemonChannels.Adapters.Telegram.Transport) == transport
        refute_received :telegram_polled
      end)

    assert log =~ "retrying lock"
    assert %{"state" => "error"} = telegram_health()
    for mod <- @stubs, do: assert(is_pid(worker_pid(mod)))

    Process.exit(holder, :kill)
    wait_until(fn -> :global.whereis_name(lock) == :undefined end)
    assert_receive :telegram_polled, 2_000
  end

  defp telegram_health do
    %{details: details} = LemonChannels.Registry.status()
    Enum.find(details, &(&1["id"] == "telegram"))
  end

  defp worker_pid(mod), do: Process.whereis(Module.concat(mod, Worker))

  defp all_pids(mods) do
    pids = Enum.map(mods, &worker_pid/1)
    if Enum.all?(pids, &is_pid/1), do: pids
  end

  defp wait_until(fun, attempts \\ 200) do
    case fun.() do
      result when result in [nil, false] and attempts > 0 ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      result when result in [nil, false] ->
        flunk("condition not met")

      result ->
        result
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_channels, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_channels, key, value)
end
