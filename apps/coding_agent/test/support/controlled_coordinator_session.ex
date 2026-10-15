defmodule CodingAgent.TestSupport.ControlledCoordinatorSession do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    test_pid = Keyword.fetch!(opts, :test_pid)
    test_ref = Process.monitor(test_pid)
    session_id = "controlled-session-#{System.unique_integer([:positive])}"
    send(test_pid, {:session_starting, self(), session_id})

    state = %{
      test_pid: test_pid,
      test_ref: test_ref,
      session_id: session_id,
      subscriber: nil,
      messages: [],
      prompt_error: Keyword.get(opts, :prompt_error),
      gate_prompt: Keyword.get(opts, :gate_prompt, false),
      gate_cleanup: Keyword.get(opts, :gate_cleanup, false)
    }

    if Keyword.get(opts, :gate_start, false) do
      receive do
        :release_start -> {:ok, state}
        {:DOWN, ^test_ref, :process, ^test_pid, _reason} -> {:stop, :normal}
      end
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, %{session_id: state.session_id}, state}
  end

  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call({:subscribe, subscriber, :direct, _opts}, _from, state) do
    session = self()
    unsubscribe = fn -> GenServer.cast(session, {:unsubscribe, subscriber}) end
    send(state.test_pid, {:session_subscribed, self(), subscriber})
    {:reply, unsubscribe, %{state | subscriber: subscriber}}
  end

  def handle_call({:prompt, text, _opts}, _from, state) do
    send(state.test_pid, {:session_prompted, self(), text})

    cond do
      state.gate_prompt ->
        receive do
          :release_prompt ->
            reply = if state.prompt_error, do: {:error, state.prompt_error}, else: :ok
            {:reply, reply, state}

          {:DOWN, ref, :process, _pid, _reason} when ref == state.test_ref ->
            {:stop, :normal, state}
        end

      state.prompt_error ->
        {:reply, {:error, state.prompt_error}, state}

      true ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast(:abort, state) do
    send(state.test_pid, {:session_aborted, self()})
    {:noreply, state}
  end

  def handle_cast({:unsubscribe, _subscriber}, state), do: {:noreply, state}

  @impl true
  def handle_info({:complete, text}, state) do
    message = %LemonAi.Types.AssistantMessage{
      content: [%LemonAi.Types.TextContent{text: text}]
    }

    send(state.subscriber, {:session_event, state.session_id, {:agent_end, [message]}})
    {:noreply, state}
  end

  def handle_info({:fail, reason}, state) do
    send(state.subscriber, {:session_event, state.session_id, {:error, reason, []}})
    {:noreply, state}
  end

  def handle_info({:terminal, status, text}, state) do
    messages =
      if is_binary(text) do
        [%LemonAi.Types.AssistantMessage{content: [%LemonAi.Types.TextContent{text: text}]}]
      else
        []
      end

    send(
      state.subscriber,
      {:session_event, state.session_id, {:stream_resync, %{reason: :overflow}}}
    )

    send(state.subscriber, {:session_terminal, state.session_id, status})
    {:noreply, %{state | messages: messages}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{test_ref: ref} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    send(state.test_pid, {:session_cleanup_started, self()})

    if state.gate_cleanup && Process.alive?(state.test_pid) do
      receive do
        :release_cleanup -> :ok
        {:DOWN, ref, :process, _pid, _reason} when ref == state.test_ref -> :ok
      end
    end

    :ok
  end
end
