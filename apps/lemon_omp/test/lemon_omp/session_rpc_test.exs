defmodule LemonOmp.SessionRpcTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport, only: [put_app_env: 2]

  alias LemonCore.Rpc.{Client, JsonLines}
  alias LemonOmp.{Manager, Projection, Session}

  # Exercise the real Session callbacks and shared client with a message-driven
  # transport. No subprocess timing, file polling or sleeps determine outcomes.
  defmodule Harness do
    use GenServer, restart: :temporary

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      observer = Keyword.fetch!(opts, :observer)
      id = Keyword.fetch!(opts, :id)
      ready = Keyword.get(opts, :ready, true)
      send_result = Keyword.get(opts, :send_result, :ok)

      {:ok, client} =
        Client.start_link(
          owner: self(),
          framing: JsonLines,
          ready: ready,
          connect_timeout: 60_000,
          send: fn bytes ->
            send(observer, {:rpc_sent, bytes})
            send_result
          end
        )

      projection = Projection.new(id: id, cwd: System.tmp_dir!())
      projection = %{projection | status: if(ready, do: :running, else: :starting)}

      {:ok,
       %{
         id: id,
         observer: observer,
         projection: projection,
         port: :test_peer,
         os_pid: nil,
         rpc_client: client,
         initial_prompt_id: nil,
         buffer: [],
         buffer_bytes: 0,
         skipping: false,
         ready?: ready,
         prompt: Keyword.get(opts, :prompt),
         resume: nil,
         start_waiters: [],
         started: nil,
         redirects: %{},
         approvals: %{},
         seq: 0,
         idle_timer: nil,
         publish_timer: nil,
         last_publish: 0,
         close_reason: nil,
         malformed: 0,
         agent_starts: if(ready, do: 1, else: 0)
       }}
    end

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, state, state}

    def handle_call({:frame, frame}, _from, state) do
      {:noreply, state} =
        Session.handle_info({state.port, {:data, {:eol, Jason.encode!(frame)}}}, state)

      {:reply, :ok, state}
    end

    def handle_call(message, from, state), do: Session.handle_call(message, from, state)

    @impl true
    def handle_cast(message, state), do: Session.handle_cast(message, state)

    @impl true
    def handle_info(message, state) do
      result = Session.handle_info(message, state)
      send(state.observer, {:processed, message})
      result
    end

    @impl true
    def terminate(_reason, state) do
      for timer <- [state.idle_timer, state.publish_timer], timer != nil do
        Process.cancel_timer(timer)
      end

      Client.fail_all(state.rpc_client, {:error, :connection_closed})
    catch
      :exit, _reason -> :ok
    end
  end

  setup do
    put_app_env(:command_timeout_ms, 60_000)
    put_app_env(:idle_timeout_ms, 0)
    :ok
  end

  defp start_session(opts \\ []) do
    id = "omp_rpc_test_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Harness, Keyword.merge(opts, observer: self(), id: id)})
    client = snapshot(pid).rpc_client

    on_exit(fn ->
      if :ets.whereis(:lemon_omp_sessions) != :undefined,
        do: :ets.delete(:lemon_omp_sessions, id)
    end)

    {pid, client}
  end

  defp snapshot(pid), do: GenServer.call(pid, :snapshot)
  defp frame(pid, frame), do: GenServer.call(pid, {:frame, frame})

  defp command do
    assert_receive {:rpc_sent, bytes}
    assert is_binary(bytes)
    assert [json, ""] = String.split(bytes, "\n")
    Jason.decode!(json)
  end

  defp respond(pid, command, fields \\ %{}) do
    frame(
      pid,
      Map.merge(
        %{
          "type" => "response",
          "id" => command["id"],
          "command" => command["type"],
          "success" => true
        },
        fields
      )
    )
  end

  defp deadline(client, id) do
    {_phase, state} = :sys.get_state(client)
    %{token: token} = Map.fetch!(state.pending, id)
    {:deadline, id, token}
  end

  test "concurrent transcript queries keep their caller-specific limits and sanitization" do
    {pid, client} = start_session()
    one = Task.async(fn -> Session.subagent(pid, "first", 1) end)
    first = command()
    two = Task.async(fn -> Session.subagent(pid, "second", 2) end)
    second = command()

    data = %{
      "sessionFile" => "/private/session",
      "messages" => [
        %{"role" => "assistant", "content" => "earlier"},
        %{"role" => "assistant", "content" => "\e[31mlatest\e[0m"}
      ]
    }

    respond(pid, second, %{"data" => data})
    respond(pid, first, %{"data" => data})
    assert {:ok, first_result} = Task.await(one)
    assert {:ok, second_result} = Task.await(two)
    assert first_result["messages"] == [%{"role" => "assistant", "text" => "latest"}]
    assert length(second_result["messages"]) == 2
    refute Map.has_key?(first_result, "sessionFile")
    refute Map.has_key?(second_result, "sessionFile")
    assert Client.pending_count(client) == 0
  end

  test "a redirect acknowledgement cannot reopen a newer turn that already finished" do
    {pid, client} = start_session()
    task = Task.async(fn -> Session.send_message(pid, "redirect", :redirect) end)
    redirect = command()
    frame(pid, %{"type" => "agent_end"})
    frame(pid, %{"type" => "agent_start"})
    frame(pid, %{"type" => "agent_end"})
    frame(pid, %{"type" => "session_settled"})
    stats = command()
    assert stats["type"] == "get_session_stats"
    respond(pid, stats, %{"data" => %{}})
    assert snapshot(pid).projection.status == :idle

    respond(pid, redirect)
    assert {:ok, %{"delivery" => "redirect"}} = Task.await(task)
    assert snapshot(pid).projection.status == :idle
    assert Client.pending_count(client) == 0
  end

  test "concurrent control calls correlate out of order without blocking cancellation" do
    {pid, client} = start_session()
    steer = Task.async(fn -> Session.send_message(pid, "line one\nline two", :steer) end)
    steer_command = command()
    assert steer_command["message"] == "line one\nline two"
    stale_deadline = deadline(client, steer_command["id"])

    cancel = Task.async(fn -> Session.cancel(pid) end)
    cancel_command = command()
    assert cancel_command["type"] == "abort"
    assert Client.pending_count(client) == 2

    respond(pid, cancel_command)
    assert {:ok, %{"cancelled" => true}} = Task.await(cancel)
    assert Client.pending_count(client) == 1

    respond(pid, steer_command, %{"success" => false, "error" => "\e[31mRefused\e[0m"})
    assert {:error, {:rejected, "Refused"}} = Task.await(steer)
    send(client, stale_deadline)
    assert Client.pending_count(client) == 0
    refute Map.has_key?(snapshot(pid), :pending)

    next = Task.async(fn -> Session.send_message(pid, "next", :follow_up) end)
    next_command = command()
    respond(pid, steer_command)
    assert Client.pending_count(client) == 1
    respond(pid, next_command)
    assert {:ok, %{"delivery" => "followUp"}} = Task.await(next)
    assert Client.pending_count(client) == 0
  end

  test "the shared deadline releases a redirect guard and ignores its late acknowledgement" do
    {pid, client} = start_session()
    task = Task.async(fn -> Session.send_message(pid, "redirect", :redirect) end)
    redirect = command()
    id = redirect["id"]
    assert snapshot(pid).projection.redirecting

    frame(pid, %{"type" => "agent_end"})
    assert snapshot(pid).projection.settling
    send(client, deadline(client, id))
    assert {:error, :outcome_unknown} = Task.await(task)
    assert_receive {:processed, {:rpc_finished, ^id, :timeout}}

    stats = command()
    assert stats["type"] == "get_session_stats"
    respond(pid, stats, %{"data" => %{}})
    respond(pid, redirect)
    state = snapshot(pid)
    assert state.projection.status == :idle
    refute state.projection.redirecting
    assert state.redirects == %{}
    assert Client.pending_count(client) == 0
    refute_received {:rpc_sent, _bytes}
  end

  test "a dead configuration caller cannot issue the next mutation or snapshot" do
    {pid, client} = start_session()

    {caller, monitor} =
      spawn_monitor(fn ->
        Session.configure(pid, [
          {"model", "set_model", %{"provider" => "fake", "modelId" => "new"}},
          {"thinking", "set_thinking_level", %{"level" => "low"}}
        ])
      end)

    first = command()
    id = first["id"]
    assert first["type"] == "set_model"
    assert Client.pending_count(client) == 1
    assert {:monitors, monitors} = Process.info(client, :monitors)
    assert {:process, caller} in monitors

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    assert_receive {:processed, {:rpc_finished, ^id, :caller_down}}
    assert Client.pending_count(client) == 0
    assert {:monitors, monitors} = Process.info(client, :monitors)
    refute {:process, caller} in monitors

    respond(pid, first)
    assert snapshot(pid).seq == 1
    refute_received {:rpc_sent, _bytes}
  end

  test "a timed-out second configuration step preserves the first receipt and refreshes state" do
    {pid, client} = start_session()

    task =
      Task.async(fn ->
        Session.configure(pid, [
          {"model", "set_model", %{"provider" => "fake", "modelId" => "new"}},
          {"thinking", "set_thinking_level", %{"level" => "low"}}
        ])
      end)

    first = command()
    assert first["type"] == "set_model"
    respond(pid, first)
    second = command()
    assert second["type"] == "set_thinking_level"
    send(client, deadline(client, second["id"]))

    refresh = command()
    assert refresh["type"] == "get_state"

    respond(pid, refresh, %{
      "data" => %{"model" => %{"provider" => "fake", "id" => "new"}, "thinkingLevel" => "high"}
    })

    assert {:error, {:partially_applied, ["model"], "thinking", :outcome_unknown}} =
             Task.await(task)

    assert snapshot(pid).projection.model == "fake/new"
    assert snapshot(pid).projection.thinking == "high"
    assert Client.pending_count(client) == 0
    assert {:ok, ^pid, %{"model" => "fake/new"}} = Manager.lookup(snapshot(pid).id)
    refute_received {:rpc_sent, _bytes}
  end

  test "initial prompt silence uses the shared deadline and leaves startup outcome unknown" do
    {pid, client} = start_session(ready: false, prompt: "initial")
    waiter = Task.async(fn -> Session.await_started(pid, 5_000) end)
    frame(pid, %{"type" => "ready"})
    subscription = command()
    stats = command()
    prompt = command()
    assert prompt["type"] == "prompt"
    respond(pid, subscription)
    respond(pid, stats, %{"data" => %{}})
    send(client, deadline(client, prompt["id"]))
    assert {:error, :outcome_unknown} = Task.await(waiter)
    assert Client.pending_count(client) == 0

    respond(pid, prompt)
    assert snapshot(pid).projection.status == :starting
    refute Map.has_key?(snapshot(pid), :ready_timer)
  end

  test "an acknowledged redirect still records its later prompt failure" do
    {pid, client} = start_session()
    task = Task.async(fn -> Session.send_message(pid, "redirect", :redirect) end)
    redirect = command()
    respond(pid, redirect)
    assert {:ok, %{"delivery" => "redirect"}} = Task.await(task)
    assert Client.pending_count(client) == 0

    respond(pid, redirect, %{"success" => false, "error" => "Prompt failed"})
    stats = command()
    respond(pid, stats, %{"data" => %{}})
    state = snapshot(pid)
    assert state.projection.status == :idle
    assert state.projection.output.error == "Prompt failed"
    assert Client.pending_count(client) == 0
  end

  test "port exit fails every pending command and stops its client without replay" do
    {pid, client} = start_session()
    session_monitor = Process.monitor(pid)
    client_monitor = Process.monitor(client)
    first = Task.async(fn -> Session.send_message(pid, "one", :steer) end)
    command()
    second = Task.async(fn -> Session.cancel(pid) end)
    command()
    assert Client.pending_count(client) == 2

    send(pid, {:test_peer, {:exit_status, 0}})
    assert {:error, :not_running} = Task.await(first)
    assert {:error, :not_running} = Task.await(second)
    assert_receive {:DOWN, ^session_monitor, :process, ^pid, :normal}
    assert_receive {:DOWN, ^client_monitor, :process, ^client, :normal}
    refute_received {:rpc_sent, _bytes}
  end

  test "a normally exiting RPC client finalizes its wrapper and fails a pending caller" do
    {pid, client} = start_session()
    monitor = Process.monitor(pid)
    task = Task.async(fn -> Session.cancel(pid) end)
    command()
    Client.peer_down(client, :disconnected)
    assert {:error, :not_running} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    refute_received {:rpc_sent, _bytes}
  end

  test "transport send failure returns immediately without registering or replaying" do
    {pid, client} = start_session(send_result: {:error, :connection_closed})
    assert {:error, :not_running} = Session.send_message(pid, "one", :steer)
    assert command()["type"] == "steer"
    assert Client.pending_count(client) == 0
    assert snapshot(pid).seq == 1
    refute_received {:rpc_sent, _bytes}
  end
end
