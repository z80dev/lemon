defmodule CodingAgent.Session.SteeringJournal do
  @moduledoc false

  alias CodingAgent.Session.MessageSerialization
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry

  @accepted "lemon.input_accepted"
  @withdrawn "lemon.input_withdrawn"
  @bound "lemon.input_bound"
  @turn "lemon.model_turn"
  @binding "lemonInput"

  def identify(message, opts \\ []) do
    id = Keyword.get(opts, :id) || Map.get(message, :id) || LemonCore.Id.uuid()
    Map.put(message, :id, id)
  end

  def accept(state, kind, message, opts \\ []) do
    id = Map.fetch!(message, :id)
    preempt = Keyword.get(opts, :preempt, true)

    case Map.get(state.input_journal, id) do
      nil ->
        data = %{
          "id" => id,
          "kind" => Atom.to_string(kind),
          "message" => CodingAgent.Session.Persistence.serialize_input(state, message),
          "acceptedAfterTurn" => state.turn_index,
          "preempt" => preempt
        }

        manager = append_sync(state.session_manager, SessionEntry.custom(@accepted, data))
        input = accepted(data, map_size(state.input_journal))

        state = %{
          state
          | session_manager: manager,
            input_journal: Map.put(state.input_journal, id, input)
        }

        {:ok, receipt(input), state, :new}

      input ->
        if input.kind == kind and input.preempt == preempt and
             input.message.content == message.content do
          {:ok, receipt(input), state, :duplicate}
        else
          {:error, :id_conflict, state}
        end
    end
  end

  # Queue ownership changes before the forwarded turn events necessarily arrive.
  # This provisional record fences withdrawal, but is not proof of consumption.
  def bind(state, ids) do
    ids = Enum.filter(ids, &match?(%{status: :pending}, Map.get(state.input_journal, &1)))

    if ids == [] do
      state
    else
      manager =
        append_sync(
          state.session_manager,
          SessionEntry.custom(@bound, %{"ids" => ids, "afterTurn" => state.turn_index})
        )

      state = %{state | session_manager: manager, is_streaming: true}

      Enum.reduce(ids, state, fn id, state ->
        inputs = Map.update!(state.input_journal, id, &%{&1 | status: :binding})
        remove_mirror(%{state | input_journal: inputs}, id)
      end)
    end
  end

  # message_end follows turn_start on the same forwarded stream. Persist the
  # accepted text and its exact consuming turn in one record, before observers.
  def persist_input(state, message) when is_map(message) do
    id = Map.get(message, :id)

    case Map.get(Map.get(state, :input_journal, %{}), id) do
      %{status: status} = input when status in [:pending, :binding] ->
        binding = %{"id" => id, "turn" => state.turn_index}
        serialized = CodingAgent.Session.Persistence.serialize_input(state, input.message)

        manager =
          case serialized do
            %{"role" => "custom"} ->
              details = Map.put(binding_details(serialized["details"]), @binding, binding)

              SessionManager.append_custom_message(
                state.session_manager,
                Map.put(serialized, "details", details)
              )

            _ ->
              SessionManager.append_message(
                state.session_manager,
                Map.put(serialized, @binding, binding)
              )
          end

        :ok = SessionManager.checkpoint(manager)
        inputs = Map.put(state.input_journal, id, %{input | status: :bound})
        state = %{state | session_manager: manager, input_journal: inputs}
        {:ok, remove_mirror(state, id)}

      %{status: :bound} ->
        {:ok, state}

      _ ->
        :unhandled
    end
  end

  def persist_input(_state, _message), do: :unhandled

  defp binding_details(nil), do: %{}
  defp binding_details(%{} = details), do: details
  defp binding_details(details), do: %{"value" => details}

  def withdraw(state, id) do
    manager = append_sync(state.session_manager, SessionEntry.custom(@withdrawn, %{"id" => id}))
    inputs = Map.update!(state.input_journal, id, &%{&1 | status: :withdrawn})
    remove_mirror(%{state | session_manager: manager, input_journal: inputs}, id)
  end

  def queued_steer?(state, id),
    do: match?(%{kind: :steer, status: :pending}, Map.get(state.input_journal, id))

  def pending(state) do
    state.input_journal
    |> Map.values()
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.sort_by(& &1.order)
  end

  def pending_steers(state) do
    state
    |> pending()
    |> Enum.filter(&(&1.kind == :steer))
    |> Enum.map(&Map.put(receipt(&1), :text, &1.message.content))
  end

  def turn_started(state) do
    index = state.turn_index + 1

    manager =
      SessionManager.append_entry(
        state.session_manager,
        SessionEntry.custom(@turn, %{"index" => index})
      )

    %{state | session_manager: manager, turn_index: index, is_streaming: true}
  end

  @doc "Whether a session entry is the model-turn marker written at `turn_start`."
  def turn_marker?(%{type: :custom, custom_type: @turn}), do: true
  def turn_marker?(_entry), do: false

  def restore(state) do
    {inputs, turn} =
      state.session_manager
      |> SessionManager.entries()
      |> Enum.reduce({%{}, 0}, fn
        %{type: :custom, custom_type: @accepted, data: data}, {inputs, turn} ->
          input = accepted(data, map_size(inputs))
          {Map.put(inputs, input.id, input), max(turn, input.accepted_after_turn)}

        %{type: :custom, custom_type: @withdrawn, data: %{"id" => id}}, {inputs, turn} ->
          {mark(inputs, id, :withdrawn), turn}

        %{type: :custom, custom_type: @turn, data: %{"index" => index}}, {inputs, turn} ->
          {inputs, max(turn, index)}

        entry, {inputs, turn} ->
          case input_binding(entry) do
            %{"id" => id, "turn" => index} -> {mark(inputs, id, :bound), max(turn, index)}
            _ -> {inputs, turn}
          end
      end)

    state = %{
      state
      | input_journal: inputs,
        turn_index: turn,
        steering_queue: :queue.new(),
        follow_up_queue: :queue.new()
    }

    Enum.reduce(pending(state), state, fn input, state ->
      opts = [preempt: input.preempt, defer_start: true]

      case input.kind do
        :follow_up -> :ok = LemonAgent.Agent.follow_up(state.agent, input.message, opts)
        :steer -> :ok = LemonAgent.Agent.steer(state.agent, input.message, opts)
      end

      key = if input.kind == :steer and input.preempt, do: :steering_queue, else: :follow_up_queue
      Map.update!(state, key, &:queue.in(input.message, &1))
    end)
  end

  defp accepted(data, order) do
    %{
      id: data["id"],
      kind: if(data["kind"] == "steer", do: :steer, else: :follow_up),
      message: MessageSerialization.deserialize_message(data["message"]),
      accepted_after_turn: data["acceptedAfterTurn"],
      preempt: data["preempt"],
      status: :pending,
      order: order
    }
  end

  defp receipt(input),
    do: Map.take(input, [:id, :kind, :accepted_after_turn, :status])

  defp mark(inputs, id, status) do
    case Map.fetch(inputs, id) do
      {:ok, input} -> Map.put(inputs, id, %{input | status: status})
      :error -> inputs
    end
  end

  defp input_binding(%{type: :message, message: message}), do: message[@binding]

  defp input_binding(%{type: :custom_message, details: details}) when is_map(details),
    do: details[@binding]

  defp input_binding(_), do: nil

  defp append_sync(manager, entry) do
    manager = SessionManager.append_entry(manager, entry)
    :ok = SessionManager.checkpoint(manager)
    manager
  end

  defp remove_mirror(state, id) do
    state
    |> Map.update!(
      :steering_queue,
      &:queue.filter(fn message -> Map.get(message, :id) != id end, &1)
    )
    |> Map.update!(
      :follow_up_queue,
      &:queue.filter(fn message -> Map.get(message, :id) != id end, &1)
    )
  end
end
