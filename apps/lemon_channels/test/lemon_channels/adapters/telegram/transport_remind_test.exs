defmodule LemonChannels.Adapters.Telegram.TransportRemindTest do
  @moduledoc """
  `/remind`, `/reminders`, and `/unremind` through the real Telegram transport
  against `LemonChannels.Telegram.FakeAPI` and the automation chat commands
  behind `LemonCore.AutomationCommands`, with the cron manager replaced by
  `FakeCron`.
  """

  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram
  alias LemonChannels.Telegram.FakeAPI

  defmodule FakeCron do
    # Called from the transport process; state lives in a named Agent.
    def start_link(test_pid) do
      Agent.start_link(fn -> %{test_pid: test_pid, jobs: []} end, name: __MODULE__)
    end

    def jobs, do: Agent.get(__MODULE__, & &1.jobs)

    def add(params) do
      job =
        params
        |> Map.merge(%{
          id: "job_#{System.unique_integer([:positive])}",
          enabled: true,
          next_run_at_ms: System.system_time(:millisecond) + 20 * 60_000
        })

      Agent.update(__MODULE__, fn state ->
        send(state.test_pid, {:cron_add, params})
        %{state | jobs: [job | state.jobs]}
      end)

      {:ok, job}
    end

    def list, do: jobs()

    def remove(id) do
      Agent.get_and_update(__MODULE__, fn state ->
        if Enum.any?(state.jobs, &(&1.id == id)) do
          send(state.test_pid, {:cron_remove, id})
          {:ok, %{state | jobs: Enum.reject(state.jobs, &(&1.id == id))}}
        else
          {{:error, :not_found}, state}
        end
      end)
    end
  end

  defmodule Commands do
    @behaviour LemonCore.AutomationCommands

    @impl true
    def handle(command, args, opts),
      do:
        LemonAutomation.ChatCommands.handle(
          command,
          args,
          Keyword.put(opts, :cron_module, FakeCron)
        )
  end

  @gateway_config_key :"Elixir.LemonGateway.Config"

  setup do
    unless Process.whereis(LemonChannels.Adapters.Telegram.AsyncSupervisor) do
      start_supervised!({Task.Supervisor, name: LemonChannels.Adapters.Telegram.AsyncSupervisor})
    end

    stop_transport()
    FakeAPI.reset()

    {:ok, _} = Application.ensure_all_started(:lemon_automation)
    previous_commands = LemonCore.AutomationCommands.provider()
    previous_gateway = Application.get_env(:lemon_gateway, @gateway_config_key)
    :ok = LemonCore.AutomationCommands.register(Commands)

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      telegram: %{bot_token: "fake-token", api_mod: FakeAPI}
    })

    start_supervised!(%{id: FakeCron, start: {FakeCron, :start_link, [self()]}})

    on_exit(fn ->
      stop_transport()
      FakeAPI.reset()
      :ok = LemonCore.AutomationCommands.register(previous_commands)
      restore_env(:lemon_gateway, @gateway_config_key, previous_gateway)
    end)

    :ok
  end

  test "an allowed chat creates, lists, and cancels a reminder" do
    chat_id = 340_001
    assert {:ok, _pid} = start_transport(%{allowed_chat_ids: [chat_id]})

    FakeAPI.simulate_message(chat_id, "/remind in 20m check oven")

    assert_receive {:cron_add, params}, 2_000
    assert params.once == true
    assert params.timezone == "local"
    assert params.session_key =~ ":telegram:"
    assert LemonCore.SessionKey.parse(params.session_key).peer_id == Integer.to_string(chat_id)
    assert params.meta["reminder"] == true

    [%{id: job_id}] = FakeCron.jobs()

    confirmation = await_text(chat_id, "Reminder set: check oven")
    assert confirmation =~ job_id
    assert confirmation =~ ~r/Next run: \w{3} \d{4}-\d{2}-\d{2} \d{2}:\d{2}/

    FakeAPI.simulate_message(chat_id, "/reminders")
    listing = await_text(chat_id, "Reminders\n")
    assert listing =~ job_id
    assert listing =~ "check oven"

    FakeAPI.simulate_message(chat_id, "/unremind #{job_id}")
    assert_receive {:cron_remove, ^job_id}, 2_000
    assert await_text(chat_id, "cancelled") =~ job_id
    assert FakeCron.jobs() == []
  end

  test "a chat outside allowed_chat_ids cannot create reminders" do
    chat_id = 340_010
    stranger_id = 340_011
    assert {:ok, _pid} = start_transport(%{allowed_chat_ids: [chat_id]})

    FakeAPI.simulate_message(stranger_id, "/remind in 20m open the door")
    # Updates are processed in order; once the allowed chat's reply lands, the
    # stranger's earlier update has been handled (dropped).
    FakeAPI.simulate_message(chat_id, "/reminders")

    assert await_text(chat_id, "No reminders") =~ "No reminders"
    refute_received {:cron_add, _}
    assert FakeCron.jobs() == []

    assert FakeAPI.sent(fn
             %{fun: :send_message, args: [^stranger_id | _]} -> true
             _ -> false
           end) == []
  end

  defp await_text(chat_id, fragment) do
    assert {:ok, %{args: [^chat_id, text | _]}} =
             FakeAPI.await_send(
               fn
                 %{fun: :send_message, args: [^chat_id, text | _]} ->
                   String.contains?(text, fragment)

                 _ ->
                   false
               end,
               2_000
             )

    text
  end

  defp start_transport(overrides) when is_map(overrides) do
    token = "remind-test-#{System.pid()}-#{System.unique_integer([:positive])}"

    config =
      %{
        bot_token: token,
        api_mod: FakeAPI,
        poll_interval_ms: 10,
        debounce_ms: 10
      }
      |> Map.merge(overrides)

    case LemonChannels.Registry.register(Telegram) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
    end

    Telegram.Transport.start_link(config: config)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp stop_transport do
    if pid = Process.whereis(LemonChannels.Adapters.Telegram.Transport) do
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end

    if Process.whereis(LemonChannels.Registry) do
      LemonChannels.Registry.unregister("telegram")
    end
  catch
    :exit, _ -> :ok
  end
end
