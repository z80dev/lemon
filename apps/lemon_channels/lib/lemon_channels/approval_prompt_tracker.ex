defmodule LemonChannels.ApprovalPromptTracker do
  @moduledoc """
  Remembers delivered remote approval prompts so an approval that Core expires
  because its owning run ended can be edited in place, even if nobody clicks it.

  Prompts are registered before they are enqueued (see
  `LemonChannels.RemoteApproval.prompt/6`). The Outbox delivery ack supplies the
  platform message id. When Core publishes `:approval_resolved` with
  `decision: :expired` on `exec_approvals`, the tracked prompt is edited to the
  expired text with its buttons cleared. Any other resolution forgets the entry
  because the click path already edits the prompt. Tracking is best-effort and
  volatile; the table is bounded and the oldest entry is evicted first.
  """
  use GenServer

  alias LemonChannels.RemoteApproval
  alias LemonCore.{Bus, Event}

  @notify_tag :approval_prompt_delivered
  @max_entries 500

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Outbox ack tag for tracked prompts."
  def notify_tag, do: @notify_tag

  @doc """
  Register a prompt before enqueueing it. Returns the tracker pid and the notify
  ref to place on the outbound payload, or `:error` when tracking is unavailable.
  """
  def track(approval_id, target, cleared_meta) when is_binary(approval_id) do
    GenServer.call(__MODULE__, {:track, approval_id, target, cleared_meta})
  catch
    :exit, _ -> :error
  end

  def track(_, _, _), do: :error

  @doc "Forget a registered prompt whose enqueue failed."
  def forget(ref) when is_reference(ref) do
    GenServer.cast(__MODULE__, {:forget, ref})
  end

  @impl true
  def init(opts) do
    :ok = Bus.subscribe("exec_approvals")

    {:ok,
     %{
       prompts: %{},
       seq: 0,
       max_entries: Keyword.get(opts, :max_entries, @max_entries),
       enqueue: Keyword.get(opts, :enqueue, &LemonChannels.Outbox.enqueue/1)
     }}
  end

  @impl true
  def handle_call({:track, approval_id, target, cleared_meta}, _from, state) do
    ref = make_ref()
    seq = state.seq + 1

    entry = %{
      approval_id: approval_id,
      target: target,
      meta: cleared_meta,
      message_id: nil,
      expired?: false,
      seq: seq
    }

    prompts = state.prompts |> Map.put(ref, entry) |> evict(state.max_entries)
    {:reply, {:ok, self(), ref}, %{state | prompts: prompts, seq: seq}}
  end

  @impl true
  def handle_cast({:forget, ref}, state),
    do: {:noreply, %{state | prompts: Map.delete(state.prompts, ref)}}

  @impl true
  def handle_info({@notify_tag, ref, {:ok, result}}, state) do
    case Map.fetch(state.prompts, ref) do
      {:ok, %{expired?: true} = entry} ->
        case message_id(result) do
          nil -> :ok
          id -> edit_expired(state, entry, id)
        end

        {:noreply, %{state | prompts: Map.delete(state.prompts, ref)}}

      {:ok, entry} ->
        case message_id(result) do
          nil ->
            {:noreply, %{state | prompts: Map.delete(state.prompts, ref)}}

          id ->
            {:noreply, %{state | prompts: Map.put(state.prompts, ref, %{entry | message_id: id})}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({@notify_tag, ref, _failure}, state),
    do: {:noreply, %{state | prompts: Map.delete(state.prompts, ref)}}

  def handle_info(%Event{type: :approval_resolved, payload: payload}, state)
      when is_map(payload) do
    id = field(payload, :approval_id)
    expired? = field(payload, :decision) in [:expired, "expired"]

    prompts =
      Enum.reduce(state.prompts, state.prompts, fn
        {ref, %{approval_id: ^id} = entry}, acc ->
          cond do
            not expired? ->
              Map.delete(acc, ref)

            entry.message_id ->
              edit_expired(state, entry, entry.message_id)
              Map.delete(acc, ref)

            true ->
              Map.put(acc, ref, %{entry | expired?: true})
          end

        _, acc ->
          acc
      end)

    {:noreply, %{state | prompts: prompts}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp field(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp edit_expired(state, entry, message_id) do
    _ =
      RemoteApproval.edit(entry.target, message_id, :expired, entry.meta, enqueue: state.enqueue)

    :ok
  end

  defp evict(prompts, max) when map_size(prompts) > max do
    {oldest, _} = Enum.min_by(prompts, fn {_ref, entry} -> entry.seq end)
    prompts |> Map.delete(oldest) |> evict(max)
  end

  defp evict(prompts, _max), do: prompts

  defp message_id({:ok, result}), do: message_id(result)
  defp message_id(id) when is_integer(id), do: id
  defp message_id(id) when is_binary(id) and id != "", do: id
  defp message_id(%{message_id: id}), do: message_id(id)
  defp message_id(%{"message_id" => id}), do: message_id(id)
  defp message_id(%{"result" => %{"message_id" => id}}), do: message_id(id)
  defp message_id(_), do: nil
end
