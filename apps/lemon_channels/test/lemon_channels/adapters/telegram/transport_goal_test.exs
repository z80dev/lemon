defmodule LemonChannels.Adapters.Telegram.TransportGoalTest do
  @moduledoc """
  `/goal continue` and `/goal loop once` through the real Telegram transport
  against `LemonChannels.Telegram.FakeAPI`: the judge/continuation runs off the
  transport process, the chat gets an immediate acknowledgement and the result
  (or an unknown-outcome notice) as a follow-up.
  """

  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram
  alias LemonChannels.Telegram.FakeAPI

  defmodule BlockingLoop do
    @moduledoc false

    def run_once(session_key, opts) do
      send(:persistent_term.get({__MODULE__, :pid}), {:run_once, self(), opts})

      receive do
        :finish ->
          {:ok,
           %{
             run_id: "run_goal_chat",
             goal: %{id: "goal_chat", status: "active", objective: "x", continuation_count: 1},
             verdict: %{action: :continue, reason: "more to do"}
           }}

        :timeout ->
          exit({:timeout, {GenServer, :call, [__MODULE__, {:run_once, session_key}, 1]}})
      end
    end
  end

  @gateway_config_key :gateway_test_config
  @chat 555_101
  @user 555_101

  setup do
    unless Process.whereis(LemonChannels.Adapters.Telegram.AsyncSupervisor) do
      start_supervised!({Task.Supervisor, name: LemonChannels.Adapters.Telegram.AsyncSupervisor})
    end

    stop_transport()
    FakeAPI.reset()
    root = Path.join(System.tmp_dir!(), "goal-chat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous_gateway = Application.get_env(:lemon_core, @gateway_config_key)
    previous_loop = Application.get_env(:lemon_channels, :goal_loop_module)
    :persistent_term.put({BlockingLoop, :pid}, self())
    Application.put_env(:lemon_channels, :goal_loop_module, BlockingLoop)

    Application.put_env(:lemon_core, @gateway_config_key, %{
      telegram: %{bot_token: "fake-token", api_mod: FakeAPI},
      bindings: [%{transport: :telegram, chat_id: @chat, project: "goal-chat"}],
      projects: %{"goal-chat" => %{root: root}}
    })

    on_exit(fn ->
      stop_transport()
      FakeAPI.reset()
      :persistent_term.erase({BlockingLoop, :pid})
      restore_env(:lemon_core, @gateway_config_key, previous_gateway)
      restore_env(:lemon_channels, :goal_loop_module, previous_loop)
      File.rm_rf!(root)
    end)

    assert {:ok, pid} = start_transport(%{allowed_chat_ids: [@chat]})
    %{transport: pid}
  end

  for {command, ack, result} <- [
        {"/goal loop once", "Goal Loop Tick Queued", "Verdict: continue"},
        {"/goal continue", "Goal Continuation Queued", "Goal Continuation Submitted"}
      ] do
    test "#{command} acknowledges at once and the transport keeps serving", %{transport: pid} do
      # Warm the command path so the timing below measures only the ack.
      FakeAPI.simulate_message(@chat, "/goal help", user_id: @user)
      assert await_text("Goal Commands")
      FakeAPI.clear()

      started = System.monotonic_time(:millisecond)
      FakeAPI.simulate_message(@chat, unquote(command), user_id: @user)
      assert await_text(unquote(ack)) =~ "result will be posted"
      assert System.monotonic_time(:millisecond) - started < 1_000
      assert_receive {:run_once, worker, _opts}, 2_000
      FakeAPI.clear()

      # A second update is handled while the judge/continuation still runs.
      FakeAPI.simulate_message(@chat, "/goal help", user_id: @user)
      assert await_text("Goal Commands") =~ "/goal loop once"
      assert Process.alive?(worker)

      send(worker, :finish)
      text = await_text(unquote(result))
      assert text =~ "Run id: run_goal_chat"
      assert Process.alive?(pid)
    end
  end

  test "a judge that hits its call timeout leaves the transport alive and reports it", %{
    transport: pid
  } do
    FakeAPI.simulate_message(@chat, "/goal loop once", user_id: @user)
    assert await_text("Goal Loop Tick Queued")
    assert_receive {:run_once, worker, _opts}, 2_000

    send(worker, :timeout)
    assert await_text("outcome unknown") =~ "/goal loop status"
    assert Process.alive?(pid)

    FakeAPI.simulate_message(@chat, "/goal help", user_id: @user)
    assert await_text("Goal Commands")
  end

  defp await_text(fragment) do
    assert {:ok, %{args: [@chat, text | _]}} =
             FakeAPI.await_send(
               fn
                 %{fun: :send_message, args: [@chat, text | _]} ->
                   String.contains?(text, fragment)

                 _ ->
                   false
               end,
               2_000
             )

    text
  end

  defp start_transport(overrides) do
    token = "goal-test-#{System.pid()}-#{System.unique_integer([:positive])}"

    config =
      %{bot_token: token, api_mod: FakeAPI, poll_interval_ms: 10, debounce_ms: 10}
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
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end

    if Process.whereis(LemonChannels.Registry),
      do: LemonChannels.Registry.unregister("telegram")
  catch
    :exit, _ -> :ok
  end
end
