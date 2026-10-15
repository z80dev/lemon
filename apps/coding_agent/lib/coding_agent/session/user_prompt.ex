defmodule CodingAgent.Session.UserPrompt do
  @moduledoc """
  Session-scoped interactive prompt port. A client binds its live connection to a
  session key before running tools. Questions travel through the normal Bus event
  bridge; answers bind the prompt, session, run and connection identities.

  Waiters, surfaces, cancellation and deadlines are owned by one GenServer, like
  execution approval transitions. No answer is selected on decline, timeout,
  disconnect or caller death. Nothing is persisted and no approval grants are
  installed. A new runtime or connection must explicitly bind a prompt surface.
  """
  use GenServer

  alias LemonCore.{Bus, Event}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def bind(session_key, connection, opts \\ [])
      when is_binary(session_key) and is_pid(connection),
      do: GenServer.call(__MODULE__, {:bind, session_key, connection, opts})

  def unbind(session_key, connection),
    do: GenServer.call(__MODULE__, {:unbind, session_key, connection})

  def bound?(session_key) when is_binary(session_key) do
    GenServer.call(__MODULE__, {:bound, session_key})
  catch
    :exit, _ -> false
  end

  def bound?(_), do: false

  @doc "Request questions and wait for a real answer; timeout_ms defaults to :infinity."
  def request(session_key, run_id, questions, opts \\ []) do
    GenServer.call(__MODULE__, {:request, session_key, run_id, questions, opts}, :infinity)
  catch
    :exit, _ -> {:error, :client_down}
  end

  def resolve(prompt_id, session_key, run_id, response, connection) do
    GenServer.call(__MODULE__, {:resolve, prompt_id, session_key, run_id, response, connection})
  end

  @impl true
  def init(_opts), do: {:ok, %{surfaces: %{}, pending: %{}}}

  @impl true
  def handle_call({:bind, key, connection, opts}, _from, state) do
    state = remove_surface(state, key)

    surface = %{
      pid: connection,
      monitor: Process.monitor(connection),
      max_timeout_ms: Keyword.get(opts, :max_timeout_ms, :infinity)
    }

    state = put_in(state.surfaces[key], surface)
    # Rebinding the same session can recover an event missed while switching UI.
    Enum.each(state.pending, fn {_id, pending} ->
      if pending.session_key == key, do: publish(:user_prompt_requested, pending.public)
    end)

    {:reply, :ok, state}
  end

  def handle_call({:unbind, key, connection}, _from, state) do
    if get_in(state.surfaces, [key, :pid]) == connection do
      {:reply, :ok, state |> remove_surface(key) |> cancel_session(key, :client_down)}
    else
      {:reply, {:error, :mismatch}, state}
    end
  end

  def handle_call({:bound, key}, _from, state) do
    pid = get_in(state.surfaces, [key, :pid])
    {:reply, is_pid(pid) and Process.alive?(pid), state}
  end

  def handle_call({:request, key, run_id, questions, opts}, from, state) do
    pid = get_in(state.surfaces, [key, :pid])
    timeout = Keyword.get(opts, :timeout_ms, :infinity)
    maximum = get_in(state.surfaces, [key, :max_timeout_ms]) || :infinity

    timeout =
      cond do
        timeout == :infinity -> maximum
        is_integer(timeout) and timeout > 0 -> min(timeout, maximum)
        true -> timeout
      end

    signal = Keyword.get(opts, :signal)

    cond do
      not is_pid(pid) or not Process.alive?(pid) ->
        {:reply, {:error, :no_client}, state}

      not (timeout == :infinity or (is_integer(timeout) and timeout > 0)) ->
        {:reply, {:error, :invalid_timeout}, state}

      LemonAgent.AbortSignal.aborted?(signal) ->
        {:reply, {:error, :cancelled}, state}

      Enum.any?(state.pending, fn {_, pending} -> pending.session_key == key end) ->
        {:reply, {:error, :prompt_pending}, state}

      true ->
        id = LemonCore.Id.uuid()
        now = System.system_time(:millisecond)

        public = %{
          "promptId" => id,
          "sessionKey" => key,
          "runId" => run_id,
          "questions" => questions,
          "requestedAtMs" => now,
          "expiresAtMs" => if(timeout == :infinity, do: nil, else: now + timeout)
        }

        pending = %{
          session_key: key,
          run_id: run_id,
          from: from,
          monitor: Process.monitor(elem(from, 0)),
          signal: signal,
          timer:
            if(timeout == :infinity,
              do: nil,
              else: Process.send_after(self(), {:timeout, id}, timeout)
            ),
          abort_timer:
            if(is_reference(signal), do: Process.send_after(self(), {:check_abort, id}, 50)),
          public: public
        }

        state = put_in(state.pending[id], pending)
        publish(:user_prompt_requested, public)
        {:noreply, state}
    end
  end

  def handle_call({:resolve, id, key, run_id, response, connection}, _from, state) do
    case Map.get(state.pending, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pending ->
        cond do
          pending.session_key != key or pending.run_id != run_id or
              get_in(state.surfaces, [key, :pid]) != connection ->
            {:reply, {:error, :mismatch}, state}

          is_integer(pending.public["expiresAtMs"]) and
              pending.public["expiresAtMs"] <= System.system_time(:millisecond) ->
            {:reply, {:error, :expired}, finish(state, id, {:error, :timeout}, "timed_out")}

          not is_map(response) or response["action"] not in ["accept", "decline", "cancel"] ->
            {:reply, {:error, :invalid_response}, state}

          true ->
            {:reply, :ok, finish(state, id, {:ok, response}, response["action"])}
        end
    end
  end

  @impl true
  def handle_info({:timeout, id}, state),
    do: {:noreply, finish(state, id, {:error, :timeout}, "timed_out")}

  def handle_info({:check_abort, id}, state) do
    case state.pending[id] do
      nil ->
        {:noreply, state}

      pending ->
        if LemonAgent.AbortSignal.aborted?(pending.signal) do
          {:noreply, finish(state, id, {:error, :cancelled}, "cancelled")}
        else
          timer = Process.send_after(self(), {:check_abort, id}, 50)
          {:noreply, put_in(state.pending[id].abort_timer, timer)}
        end
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state.surfaces, state, fn {key, surface}, acc ->
        if surface.monitor == monitor,
          do: acc |> remove_surface(key) |> cancel_session(key, :client_down),
          else: acc
      end)

    state =
      Enum.reduce(state.pending, state, fn {id, pending}, acc ->
        if pending.monitor == monitor,
          do: finish(acc, id, {:error, :cancelled}, "cancelled"),
          else: acc
      end)

    {:noreply, state}
  end

  defp finish(state, id, reply, status) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {pending, rest} ->
        Process.demonitor(pending.monitor, [:flush])
        if pending.timer, do: Process.cancel_timer(pending.timer)
        if pending.abort_timer, do: Process.cancel_timer(pending.abort_timer)
        GenServer.reply(pending.from, reply)

        public =
          pending.public
          |> Map.take(["promptId", "sessionKey", "runId"])
          |> Map.put("status", status)

        publish(:user_prompt_resolved, public)
        %{state | pending: rest}
    end
  end

  defp cancel_session(state, key, reason) do
    Enum.reduce(state.pending, state, fn {id, pending}, acc ->
      if pending.session_key == key, do: finish(acc, id, {:error, reason}, "cancelled"), else: acc
    end)
  end

  defp remove_surface(state, key) do
    case Map.pop(state.surfaces, key) do
      {nil, _} ->
        state

      {surface, rest} ->
        Process.demonitor(surface.monitor, [:flush])
        %{state | surfaces: rest}
    end
  end

  defp publish(type, payload) do
    Bus.broadcast(
      "user_prompts",
      Event.new(type, payload, %{session_key: payload["sessionKey"], run_id: payload["runId"]})
    )
  end
end
