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

  require Logger

  @notify_tag :presentation_delivery

  # How long a pending_create_ref is allowed to exist before being
  # considered stale and eligible for garbage collection (30 seconds).
  # A stale ref means the delivery notification was lost (e.g., due to a
  # PresentationState crash or an Outbox retry that exhausted attempts).
  @pending_create_ttl_ms 30_000

  @type surface :: term()
  @type entry :: %{
          route: DeliveryRoute.t(),
          run_id: binary(),
          surface: surface(),
          platform_message_id: integer() | binary() | nil,
          pending_create_ref: reference() | nil,
          pending_create_at: integer() | nil,
          pending_edit_ref: reference() | nil,
          pending_edit_at: integer() | nil,
          last_seq: non_neg_integer(),
          last_text_hash: integer() | nil,
          deferred_text: binary() | nil,
          deferred_chunks: [binary()] | nil,
          pending_followup_chunks: [binary()] | nil,
          deferred_seq: non_neg_integer() | nil,
          deferred_hash: integer() | nil,
          deferred_meta: map(),
          pending_followup_meta: map(),
          pending_resume: term() | nil
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec notify_tag() :: atom()
  def notify_tag, do: @notify_tag

  @spec get(DeliveryRoute.t(), binary(), surface()) :: entry()
  def get(%DeliveryRoute{} = route, run_id, surface)
      when is_binary(run_id) do
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
      when is_binary(run_id) and is_reference(ref) and is_integer(seq) do
    GenServer.call(
      __MODULE__,
      {:register_pending_create, key(route, run_id, surface), route, run_id, surface, ref, seq,
       text_hash, pending_resume}
    )
  end

  @spec register_pending_edit(
          DeliveryRoute.t(),
          binary(),
          surface(),
          reference(),
          non_neg_integer(),
          integer() | nil,
          integer() | binary() | nil
        ) :: :ok
  def register_pending_edit(
        %DeliveryRoute{} = route,
        run_id,
        surface,
        ref,
        seq,
        text_hash,
        message_id
      )
      when is_binary(run_id) and is_reference(ref) and is_integer(seq) do
    GenServer.call(
      __MODULE__,
      {:register_pending_edit, key(route, run_id, surface), route, run_id, surface, ref, seq,
       text_hash, message_id}
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
      when is_binary(run_id) and is_binary(text) and is_integer(seq) and
             is_map(deferred_meta) do
    GenServer.call(
      __MODULE__,
      {:defer_text, key(route, run_id, surface), route, run_id, surface, text, seq, text_hash,
       deferred_meta}
    )
  end

  @spec defer_chunks(
          DeliveryRoute.t(),
          binary(),
          surface(),
          [binary()],
          non_neg_integer(),
          integer() | nil,
          map()
        ) :: :ok
  def defer_chunks(
        %DeliveryRoute{} = route,
        run_id,
        surface,
        chunks,
        seq,
        text_hash,
        deferred_meta \\ %{}
      )
      when is_binary(run_id) and is_list(chunks) and is_integer(seq) and is_map(deferred_meta) do
    GenServer.call(
      __MODULE__,
      {:defer_chunks, key(route, run_id, surface), route, run_id, surface, chunks, seq, text_hash,
       deferred_meta}
    )
  end

  @spec stage_followups(DeliveryRoute.t(), binary(), surface(), [binary()], map()) :: :ok
  def stage_followups(
        %DeliveryRoute{} = route,
        run_id,
        surface,
        chunks,
        followup_meta \\ %{}
      )
      when is_binary(run_id) and is_list(chunks) and is_map(followup_meta) do
    GenServer.call(
      __MODULE__,
      {:stage_followups, key(route, run_id, surface), route, run_id, surface, chunks,
       followup_meta}
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
      when is_binary(run_id) and is_integer(seq) do
    GenServer.call(
      __MODULE__,
      {:mark_sent, key(route, run_id, surface), route, run_id, surface, seq, text_hash,
       message_id}
    )
  end

  @spec clear(DeliveryRoute.t(), binary(), surface()) :: :ok
  def clear(%DeliveryRoute{} = route, run_id, surface)
      when is_binary(run_id) do
    GenServer.call(__MODULE__, {:clear, key(route, run_id, surface)})
  end

  @spec move(DeliveryRoute.t(), binary(), surface(), surface()) :: :ok
  def move(%DeliveryRoute{} = route, run_id, from_surface, to_surface)
      when is_binary(run_id) do
    GenServer.call(
      __MODULE__,
      {:move, key(route, run_id, from_surface), key(route, run_id, to_surface), route, run_id,
       from_surface, to_surface}
    )
  end

  @impl true
  def init(_state) do
    {:ok, %{entries: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:get, key, route, run_id, surface}, _from, state) do
    {entry, state} = get_with_stale_gc(key, route, run_id, surface, state)
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
        pending_create_at: System.monotonic_time(:millisecond),
        last_seq: seq,
        last_text_hash: text_hash,
        pending_resume: pending_resume
      })

    state =
      state
      |> put_entry(key, entry)
      |> put_ref(ref, {key, :create})

    {:reply, :ok, state}
  end

  def handle_call(
        {:register_pending_edit, key, route, run_id, surface, ref, seq, text_hash, message_id},
        _from,
        state
      ) do
    entry =
      state.entries
      |> Map.get(key, new_entry(route, run_id, surface))
      |> Map.merge(%{
        platform_message_id:
          message_id || Map.get(state.entries[key] || %{}, :platform_message_id),
        pending_edit_ref: ref,
        pending_edit_at: System.monotonic_time(:millisecond),
        last_seq: seq,
        last_text_hash: text_hash
      })

    state =
      state
      |> put_entry(key, entry)
      |> put_ref(ref, {key, :edit})

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
        deferred_chunks: nil,
        deferred_seq: seq,
        deferred_hash: text_hash,
        deferred_meta: deferred_meta
      })

    state =
      state
      |> put_entry(key, entry)
      |> maybe_flush_late_deferred(key, entry)

    {:reply, :ok, state}
  end

  def handle_call(
        {:defer_chunks, key, route, run_id, surface, chunks, seq, text_hash, deferred_meta},
        _from,
        state
      ) do
    entry =
      state.entries
      |> Map.get(key, new_entry(route, run_id, surface))
      |> Map.merge(%{
        deferred_text: nil,
        deferred_chunks: Enum.filter(chunks, &(is_binary(&1) and &1 != "")),
        deferred_seq: seq,
        deferred_hash: text_hash,
        deferred_meta: deferred_meta
      })

    state =
      state
      |> put_entry(key, entry)
      |> maybe_flush_late_deferred(key, entry)

    {:reply, :ok, state}
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
        pending_create_at: nil,
        pending_edit_ref: nil,
        pending_edit_at: nil,
        deferred_text: nil,
        deferred_chunks: nil,
        pending_followup_chunks: nil,
        deferred_seq: nil,
        deferred_hash: nil,
        deferred_meta: %{},
        pending_followup_meta: %{},
        pending_resume: nil
      })

    {:reply, :ok, put_entry(state, key, entry)}
  end

  def handle_call(
        {:stage_followups, key, route, run_id, surface, chunks, followup_meta},
        _from,
        state
      ) do
    entry =
      state.entries
      |> Map.get(key, new_entry(route, run_id, surface))
      |> Map.merge(%{
        pending_followup_chunks: Enum.filter(chunks, &(is_binary(&1) and &1 != "")),
        pending_followup_meta: followup_meta(followup_meta)
      })
      |> maybe_flush_late_staged_followups()

    {:reply, :ok, put_entry(state, key, entry)}
  end

  def handle_call({:clear, key}, _from, state) do
    refs =
      state.refs
      |> Enum.reject(fn {_ref, ref_key} -> ref_matches_key?(ref_key, key) end)
      |> Map.new()

    entries = Map.delete(state.entries, key)
    {:reply, :ok, %{state | entries: entries, refs: refs}}
  end

  def handle_call(
        {:move, from_key, to_key, route, run_id, _from_surface, to_surface},
        _from,
        state
      ) do
    case Map.get(state.entries, from_key) do
      nil ->
        {:reply, :ok, state}

      entry ->
        refs =
          state.refs
          |> Enum.reject(fn {_ref, ref_key} -> ref_matches_key?(ref_key, to_key) end)
          |> Enum.map(fn
            {ref, {^from_key, kind}} -> {ref, {to_key, kind}}
            {ref, ^from_key} -> {ref, to_key}
            pair -> pair
          end)
          |> Map.new()

        moved_entry = %{entry | route: route, run_id: run_id, surface: to_surface}

        entries =
          state.entries
          |> Map.delete(from_key)
          |> Map.put(to_key, moved_entry)

        {:reply, :ok, %{state | entries: entries, refs: refs}}
    end
  end

  @impl true
  def handle_info({@notify_tag, ref, result}, state) when is_reference(ref) do
    {ref_key, refs} = Map.pop(state.refs, ref)

    state =
      case ref_key do
        nil ->
          # Ref not tracked — this can happen legitimately when the Outbox
          # chunked a payload and subsequent chunks still carry the old ref.
          # Log at debug to aid diagnosis without noise.
          Logger.debug(
            "PresentationState received notification for unknown ref (may be Outbox chunk artifact)"
          )

          %{state | refs: refs}

        ref_key ->
          {key, phase} = normalize_ref_key(ref_key)
          entry = Map.get(state.entries, key)
          state = %{state | refs: refs}

          case entry do
            nil ->
              state

            _ ->
              message_id = extract_message_id(result)
              apply_delivery_notification(state, key, entry, ref, phase, result, message_id)
          end
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_flush_deferred_edit(state, key, entry, message_id)
       when is_integer(message_id) or (is_binary(message_id) and message_id != "") do
    with [first_chunk | rest_chunks] <- deferred_chunks(entry) do
      notify_ref = make_ref()

      payload =
        OutboundPayload.edit(
          entry.route.channel_id,
          entry.route.account_id,
          peer(entry.route),
          to_string(message_id),
          first_chunk,
          meta: Map.put(entry.deferred_meta, :notify_tag, notify_tag()),
          notify_pid: Process.whereis(__MODULE__),
          notify_ref: notify_ref
        )

      case Outbox.enqueue(payload) do
        {:ok, _} ->
          entry = %{
            entry
            | pending_edit_ref: notify_ref,
              pending_edit_at: System.monotonic_time(:millisecond),
              last_seq: entry.deferred_seq || entry.last_seq,
              last_text_hash: entry.deferred_hash || entry.last_text_hash,
              deferred_text: nil,
              deferred_chunks: nil,
              pending_followup_chunks: rest_chunks,
              deferred_seq: nil,
              deferred_hash: nil,
              deferred_meta: %{},
              pending_followup_meta: followup_meta(entry.deferred_meta)
          }

          state
          |> put_entry(key, entry)
          |> put_ref(notify_ref, {key, :edit})

        _ ->
          put_entry(state, key, entry)
      end
    else
      _ -> put_entry(state, key, entry)
    end
  rescue
    _ -> put_entry(state, key, entry)
  end

  defp maybe_flush_deferred_edit(state, key, entry, _message_id), do: put_entry(state, key, entry)

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
      pending_create_at: nil,
      pending_edit_ref: nil,
      pending_edit_at: nil,
      last_seq: 0,
      last_text_hash: nil,
      deferred_text: nil,
      deferred_chunks: nil,
      pending_followup_chunks: nil,
      deferred_seq: nil,
      deferred_hash: nil,
      deferred_meta: %{},
      pending_followup_meta: %{},
      pending_resume: nil
    }
  end

  defp put_entry(state, key, entry) do
    %{state | entries: Map.put(state.entries, key, entry)}
  end

  defp put_ref(state, ref, key) do
    %{state | refs: Map.put(state.refs, ref, key)}
  end

  # Get an entry, evicting a stale pending_create_ref if it has exceeded the TTL.
  # A stale ref means the Outbox delivery notification was lost (crash, retry
  # exhaustion, etc.) and the entry is stuck deferring all future updates.
  defp get_with_stale_gc(key, route, run_id, surface, state) do
    case Map.get(state.entries, key) do
      nil ->
        {new_entry(route, run_id, surface), state}

      %{pending_create_ref: ref, pending_create_at: at} = entry
      when is_reference(ref) and is_integer(at) ->
        maybe_gc_stale_pending(state, key, entry, ref, :create, surface)

      %{pending_edit_ref: ref, pending_edit_at: at} = entry
      when is_reference(ref) and is_integer(at) ->
        maybe_gc_stale_pending(state, key, entry, ref, :edit, surface)

      entry ->
        {entry, state}
    end
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

  defp apply_delivery_notification(state, key, entry, ref, :create, result, message_id) do
    if entry.pending_create_ref != ref do
      put_entry(state, key, entry)
    else
      entry = %{entry | pending_create_ref: nil, pending_create_at: nil}

      entry =
        if is_nil(message_id) do
          Logger.debug(
            "PresentationState: delivery succeeded but message_id not extractable " <>
              "from result=#{inspect(result)}, run_id=#{entry.run_id}"
          )

          entry
        else
          maybe_index_pending_resume(entry, message_id)
          %{entry | platform_message_id: message_id, pending_resume: nil}
        end

      entry =
        if deferred_chunks(entry) == [] do
          maybe_enqueue_followups(entry)
        else
          %{entry | pending_followup_chunks: nil, pending_followup_meta: %{}}
        end

      maybe_flush_deferred_edit(state, key, entry, message_id)
    end
  end

  defp apply_delivery_notification(state, key, entry, ref, :edit, _result, _message_id) do
    if entry.pending_edit_ref != ref do
      put_entry(state, key, entry)
    else
      entry =
        %{
          entry
          | pending_edit_ref: nil,
            pending_edit_at: nil
        }

      entry =
        if deferred_chunks(entry) == [] do
          maybe_enqueue_followups(entry)
        else
          %{entry | pending_followup_chunks: nil, pending_followup_meta: %{}}
        end

      maybe_flush_deferred_edit(state, key, entry, entry.platform_message_id)
    end
  end

  defp normalize_ref_key({key, phase}) when phase in [:create, :edit], do: {key, phase}
  defp normalize_ref_key(key), do: {key, :create}

  defp ref_matches_key?({ref_key, _phase}, key), do: ref_key == key
  defp ref_matches_key?(ref_key, key), do: ref_key == key

  defp maybe_gc_stale_pending(state, key, entry, ref, phase, surface) do
    now = System.monotonic_time(:millisecond)

    if now - pending_at(entry, phase) > @pending_create_ttl_ms do
      Logger.warning(
        "PresentationState evicting stale pending_#{phase}_ref " <>
          "(#{now - pending_at(entry, phase)}ms old) for run_id=#{entry.run_id}, surface=#{surface}."
      )

      cleaned =
        case phase do
          :create -> %{entry | pending_create_ref: nil, pending_create_at: nil}
          :edit -> %{entry | pending_edit_ref: nil, pending_edit_at: nil}
        end

      refs = Map.delete(state.refs, ref)
      {cleaned, %{state | entries: Map.put(state.entries, key, cleaned), refs: refs}}
    else
      {entry, state}
    end
  end

  defp pending_at(entry, :create), do: entry.pending_create_at || 0
  defp pending_at(entry, :edit), do: entry.pending_edit_at || 0

  defp deferred_chunks(%{deferred_chunks: chunks}) when is_list(chunks) and chunks != [],
    do: chunks

  defp deferred_chunks(%{deferred_text: text}) when is_binary(text) and text != "", do: [text]
  defp deferred_chunks(_), do: []

  defp maybe_enqueue_followups(%{pending_followup_chunks: chunks} = entry)
       when is_list(chunks) and chunks != [] do
    Enum.each(chunks, fn chunk ->
      _ =
        Outbox.enqueue(
          OutboundPayload.text(
            entry.route.channel_id,
            entry.route.account_id,
            peer(entry.route),
            chunk,
            idempotency_key: nil,
            reply_to: followup_reply_to(entry.pending_followup_meta),
            meta: entry.pending_followup_meta
          )
        )
    end)

    %{entry | pending_followup_chunks: nil, pending_followup_meta: %{}}
  end

  defp maybe_enqueue_followups(entry), do: entry

  defp maybe_flush_late_staged_followups(
         %{
           platform_message_id: message_id,
           pending_create_ref: nil,
           pending_edit_ref: nil,
           pending_followup_chunks: chunks
         } = entry
       )
       when (is_integer(message_id) or (is_binary(message_id) and message_id != "")) and
              is_list(chunks) and chunks != [] do
    maybe_enqueue_followups(entry)
  end

  defp maybe_flush_late_staged_followups(entry), do: entry

  defp maybe_flush_late_deferred(
         state,
         key,
         %{
           platform_message_id: message_id,
           pending_create_ref: nil,
           pending_edit_ref: nil
         } = entry
       )
       when is_integer(message_id) or (is_binary(message_id) and message_id != "") do
    if deferred_chunks(entry) == [] do
      state
    else
      maybe_flush_deferred_edit(state, key, entry, message_id)
    end
  end

  defp maybe_flush_late_deferred(state, _key, _entry), do: state

  defp followup_meta(meta) when is_map(meta),
    do: Map.drop(meta, [:reply_markup, :controls, :notify_tag])

  defp followup_meta(_), do: %{}

  defp followup_reply_to(meta) when is_map(meta) do
    case Map.get(meta, :followup_reply_to) || Map.get(meta, "followup_reply_to") do
      nil -> nil
      reply_to -> to_string(reply_to)
    end
  end

  defp followup_reply_to(_), do: nil
end
