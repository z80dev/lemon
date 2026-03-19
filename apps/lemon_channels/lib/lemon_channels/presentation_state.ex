defmodule LemonChannels.PresentationState do
  @moduledoc """
  Tracks channel presentation state per `{route, run, surface}`.

  State is owned by `:lemon_channels` so router processes can stay semantic and
  avoid platform-specific message-id bookkeeping.
  """

  use GenServer

  alias LemonChannels.Outbox
  alias LemonChannels.OutboundPayload
  alias LemonChannels.Telegram.ResumeIndexStore
  alias LemonCore.DeliveryRoute

  @notify_tag :presentation_delivery

  @type surface :: term()
  @type entry :: %{
          route: DeliveryRoute.t(),
          run_id: binary(),
          surface: surface(),
          platform_message_id: integer() | binary() | nil,
          pending_create_ref: reference() | nil,
          last_seq: non_neg_integer(),
          last_text_hash: integer() | nil,
          deferred_text: binary() | nil,
          deferred_seq: non_neg_integer() | nil,
          deferred_hash: integer() | nil,
          deferred_meta: map(),
          pending_resume: term() | nil
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec notify_tag() :: atom()
  def notify_tag, do: @notify_tag

  @spec get(DeliveryRoute.t(), binary(), surface()) :: entry()
  def get(%DeliveryRoute{} = route, run_id, surface)
      when is_binary(run_id) and not is_nil(surface) do
    GenServer.call(__MODULE__, {:get, key(route, run_id, surface), route, run_id, surface})
  end

  @spec register_pending_create(
          DeliveryRoute.t(),
          binary(),
          surface(),
          reference(),
          non_neg_integer(),
          integer() | nil,
          term() | nil
        ) ::
          :ok
  def register_pending_create(
        %DeliveryRoute{} = route,
        run_id,
        surface,
        ref,
        seq,
        text_hash,
        pending_resume \\ nil
      )
      when is_binary(run_id) and not is_nil(surface) and is_reference(ref) and is_integer(seq) do
    GenServer.call(
      __MODULE__,
      {:register_pending_create, key(route, run_id, surface), route, run_id, surface, ref, seq,
       text_hash, pending_resume}
    )
  end

  @spec defer_text(
          DeliveryRoute.t(),
          binary(),
          surface(),
          binary(),
          non_neg_integer(),
          integer() | nil,
          map()
        ) ::
          :ok
  def defer_text(
        %DeliveryRoute{} = route,
        run_id,
        surface,
        text,
        seq,
        text_hash,
        deferred_meta \\ %{}
      )
      when is_binary(run_id) and not is_nil(surface) and is_binary(text) and is_integer(seq) and
             is_map(deferred_meta) do
    GenServer.call(
      __MODULE__,
      {:defer_text, key(route, run_id, surface), route, run_id, surface, text, seq, text_hash,
       deferred_meta}
    )
  end

  @spec mark_sent(
          DeliveryRoute.t(),
          binary(),
          surface(),
          non_neg_integer(),
          integer() | nil,
          integer() | binary() | nil
        ) ::
          :ok
  def mark_sent(%DeliveryRoute{} = route, run_id, surface, seq, text_hash, message_id \\ nil)
      when is_binary(run_id) and not is_nil(surface) and is_integer(seq) do
    GenServer.call(
      __MODULE__,
      {:mark_sent, key(route, run_id, surface), route, run_id, surface, seq, text_hash,
       message_id}
    )
  end

  @spec clear(DeliveryRoute.t(), binary(), surface()) :: :ok
  def clear(%DeliveryRoute{} = route, run_id, surface)
      when is_binary(run_id) and not is_nil(surface) do
    GenServer.call(__MODULE__, {:clear, key(route, run_id, surface)})
  end

  @spec move(DeliveryRoute.t(), binary(), surface(), surface()) :: :ok
  def move(%DeliveryRoute{} = route, run_id, from_surface, to_surface)
      when is_binary(run_id) and not is_nil(from_surface) and not is_nil(to_surface) do
    GenServer.call(
      __MODULE__,
      {:move, key(route, run_id, from_surface), key(route, run_id, to_surface), route, run_id,
       to_surface}
    )
  end

  @impl true
  def init(_state) do
    {:ok, %{entries: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:get, key, route, run_id, surface}, _from, state) do
    entry = Map.get(state.entries, key, new_entry(route, run_id, surface))
    {:reply, entry, state}
  end

  def handle_call(
        {:register_pending_create, key, route, run_id, surface, ref, seq, text_hash,
         pending_resume},
        _from,
        state
      ) do
    entry =
      state.entries
      |> Map.get(key, new_entry(route, run_id, surface))
      |> Map.merge(%{
        pending_create_ref: ref,
        last_seq: seq,
        last_text_hash: text_hash,
        pending_resume: pending_resume
      })

    state =
      state
      |> put_entry(key, entry)
      |> put_ref(ref, key)

    {:reply, :ok, state}
  end

  def handle_call(
        {:defer_text, key, route, run_id, surface, text, seq, text_hash, deferred_meta},
        _from,
        state
      ) do
    entry =
      state.entries
      |> Map.get(key, new_entry(route, run_id, surface))
      |> Map.merge(%{
        deferred_text: text,
        deferred_seq: seq,
        deferred_hash: text_hash,
        deferred_meta: deferred_meta
      })

    {:reply, :ok, put_entry(state, key, entry)}
  end

  def handle_call(
        {:mark_sent, key, route, run_id, surface, seq, text_hash, message_id},
        _from,
        state
      ) do
    entry =
      state.entries
      |> Map.get(key, new_entry(route, run_id, surface))
      |> Map.merge(%{
        last_seq: seq,
        last_text_hash: text_hash,
        platform_message_id:
          message_id || Map.get(state.entries[key] || %{}, :platform_message_id),
        pending_create_ref: nil,
        deferred_text: nil,
        deferred_seq: nil,
        deferred_hash: nil,
        deferred_meta: %{},
        pending_resume: nil
      })

    {:reply, :ok, put_entry(state, key, entry)}
  end

  def handle_call({:clear, key}, _from, state) do
    refs =
      state.refs
      |> Enum.reject(fn {_ref, ref_key} -> ref_key == key end)
      |> Map.new()

    entries = Map.delete(state.entries, key)
    {:reply, :ok, %{state | entries: entries, refs: refs}}
  end

  def handle_call({:move, from_key, to_key, route, run_id, to_surface}, _from, state) do
    {entry, entries} =
      case Map.pop(state.entries, from_key) do
        {nil, entries} -> {new_entry(route, run_id, to_surface), entries}
        {entry, entries} -> {%{entry | surface: to_surface}, entries}
      end

    refs =
      state.refs
      |> Enum.map(fn
        {ref, ^from_key} -> {ref, to_key}
        other -> other
      end)
      |> Map.new()

    state = %{state | entries: Map.put(entries, to_key, entry), refs: refs}
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({@notify_tag, ref, result}, state) when is_reference(ref) do
    {key, refs} = Map.pop(state.refs, ref)

    state =
      case key do
        nil ->
          %{state | refs: refs}

        key ->
          entry = Map.get(state.entries, key)
          state = %{state | refs: refs}

          case entry do
            nil ->
              state

            _ ->
              message_id = extract_message_id(result)
              entry = %{entry | pending_create_ref: nil}

              entry =
                if is_nil(message_id) do
                  entry
                else
                  maybe_index_pending_resume(entry, message_id)
                  %{entry | platform_message_id: message_id, pending_resume: nil}
                end

              entry = maybe_flush_deferred_edit(entry, message_id)
              put_entry(state, key, entry)
          end
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_flush_deferred_edit(entry, message_id)
       when is_integer(message_id) or (is_binary(message_id) and message_id != "") do
    with text when is_binary(text) and text != "" <- entry.deferred_text do
      payload =
        OutboundPayload.edit(
          entry.route.channel_id,
          entry.route.account_id,
          peer(entry.route),
          to_string(message_id),
          text,
          meta: entry.deferred_meta
        )

      _ = Outbox.enqueue(payload)

      %{
        entry
        | last_seq: entry.deferred_seq || entry.last_seq,
          last_text_hash: entry.deferred_hash || entry.last_text_hash,
          deferred_text: nil,
          deferred_seq: nil,
          deferred_hash: nil,
          deferred_meta: %{}
      }
    else
      _ -> entry
    end
  rescue
    _ -> entry
  end

  defp maybe_flush_deferred_edit(entry, _message_id), do: entry

  defp maybe_index_pending_resume(%{pending_resume: nil}, _message_id), do: :ok

  defp maybe_index_pending_resume(%{route: route, pending_resume: pending_resume}, message_id) do
    if route.channel_id == "telegram" do
      chat_id = parse_int(route.peer_id)
      thread_id = parse_int(route.thread_id)
      msg_id = parse_int(message_id)

      if is_integer(chat_id) and is_integer(msg_id) do
        ResumeIndexStore.put_resume(
          route.account_id || "default",
          chat_id,
          thread_id,
          msg_id,
          pending_resume
        )
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp key(%DeliveryRoute{} = route, run_id, surface) do
    {
      route.channel_id,
      route.account_id,
      route.peer_kind,
      route.peer_id,
      route.thread_id,
      run_id,
      surface
    }
  end

  defp new_entry(route, run_id, surface) do
    %{
      route: route,
      run_id: run_id,
      surface: surface,
      platform_message_id: nil,
      pending_create_ref: nil,
      last_seq: 0,
      last_text_hash: nil,
      deferred_text: nil,
      deferred_seq: nil,
      deferred_hash: nil,
      deferred_meta: %{},
      pending_resume: nil
    }
  end

  defp put_entry(state, key, entry) do
    %{state | entries: Map.put(state.entries, key, entry)}
  end

  defp put_ref(state, ref, key) do
    %{state | refs: Map.put(state.refs, ref, key)}
  end

  defp peer(%DeliveryRoute{} = route) do
    %{
      kind: normalize_peer_kind(route.peer_kind),
      id: to_string(route.peer_id),
      thread_id: route.thread_id
    }
  end

  defp normalize_peer_kind(kind) when kind in [:dm, :group, :channel], do: kind
  defp normalize_peer_kind("dm"), do: :dm
  defp normalize_peer_kind("group"), do: :group
  defp normalize_peer_kind("channel"), do: :channel
  defp normalize_peer_kind(_), do: :dm

  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {value, _} -> value
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp extract_message_id({:ok, result}), do: extract_message_id(result)
  defp extract_message_id({:error, _}), do: nil
  defp extract_message_id(result) when is_integer(result), do: result

  defp extract_message_id(result) when is_binary(result) do
    case Integer.parse(result) do
      {value, _} -> value
      :error -> nil
    end
  end

  defp extract_message_id(%{message_id: id}), do: extract_message_id(id)
  defp extract_message_id(%{"message_id" => id}), do: extract_message_id(id)
  defp extract_message_id(%{"result" => %{"message_id" => id}}), do: extract_message_id(id)
  defp extract_message_id(_), do: nil
end
