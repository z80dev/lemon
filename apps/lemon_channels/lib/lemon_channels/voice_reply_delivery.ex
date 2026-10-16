defmodule LemonChannels.VoiceReplyDelivery do
  @moduledoc """
  Coordinates opt-in speech only after every terminal answer transcript chunk is delivered.

  Intermediate finalizations marked `terminal_answer: false` never claim a voice reply.
  Transcript receipts accept text sends and edit text, ignoring accompanying attachments.
  """

  use GenServer

  alias LemonChannels.{
    CapabilityQuery,
    GatewayConfig,
    OutboundPayload,
    Outbox,
    VoiceReply
  }

  alias LemonChannels.Outbox.Chunker
  alias LemonCore.DeliveryIntent

  @retention_ms 600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Claims a stable route/run final-answer identity without waiting for synthesis."
  def prepare(%DeliveryIntent{} = intent, opts \\ []) do
    config = Keyword.get_lazy(opts, :config, fn -> channel_config(intent) end)

    supported? =
      Keyword.get_lazy(opts, :supported?, fn ->
        CapabilityQuery.supports?(intent.route.channel_id, :voice)
      end)

    if eligible?(intent, config, supported?) do
      id = identity(intent)
      intent = %{intent | intent_id: id, meta: Map.put(intent.meta || %{}, :voice_reply_id, id)}
      GenServer.call(Keyword.get(opts, :server, __MODULE__), {:prepare, intent, config, opts})
      intent
    else
      intent
    end
  catch
    :exit, _ -> intent
  end

  @doc "Registers the renderer-normalized final transcript before any chunks are enqueued."
  def expect(%DeliveryIntent{} = intent, chunks, opts \\ []) do
    id = value(intent.meta, :voice_reply_id)

    if id do
      size = Chunker.chunk_size_for(intent.route.channel_id)

      chunks =
        Enum.flat_map(chunks, fn text ->
          if String.length(text) <= size, do: [text], else: Chunker.chunk(text, chunk_size: size)
        end)

      GenServer.call(Keyword.get(opts, :server, __MODULE__), {:expect, id, chunks})
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Observes terminal outbox results, independently of presentation's message-id notifications."
  def receipt(%OutboundPayload{} = payload, result, token, opts \\ []) do
    id = get_in(payload.meta || %{}, [:intent_meta, :voice_reply_id])
    text = transcript_text(payload)

    if id && is_binary(text) do
      GenServer.cast(
        Keyword.get(opts, :server, __MODULE__),
        {:receipt, id, text, result, token}
      )
    end

    :ok
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:prepare, intent, config, opts}, _from, state) do
    id = intent.meta.voice_reply_id

    state =
      if Map.has_key?(state, id) do
        state
      else
        Process.send_after(self(), {:expire, id}, @retention_ms)

        Map.put(state, id, %{
          intent: intent,
          config: config,
          opts: opts,
          remaining: nil,
          seen: MapSet.new(),
          status: :waiting
        })
      end

    {:reply, :ok, state}
  end

  def handle_call({:expect, id, chunks}, _from, state) do
    state =
      case state[id] do
        %{remaining: nil} = entry ->
          Map.put(state, id, %{entry | remaining: Enum.frequencies(chunks)})

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:receipt, id, text, result, token}, state) do
    state =
      case state[id] do
        %{status: :waiting, remaining: remaining} = entry when is_map(remaining) ->
          if MapSet.member?(entry.seen, token) do
            state
          else
            entry = %{entry | seen: MapSet.put(entry.seen, token)}
            Map.put(state, id, apply_receipt(entry, text, result))
          end

        _ ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:expire, id}, state), do: {:noreply, Map.delete(state, id)}

  defp apply_receipt(entry, text, {:ok, _}) do
    remaining =
      case Map.get(entry.remaining, text) do
        1 -> Map.delete(entry.remaining, text)
        n when is_integer(n) and n > 1 -> Map.put(entry.remaining, text, n - 1)
        _ -> entry.remaining
      end

    if map_size(remaining) == 0 do
      supervisor =
        Keyword.get(entry.opts, :task_supervisor, LemonChannels.VoiceReplyTaskSupervisor)

      Task.Supervisor.start_child(supervisor, fn -> synthesize_and_deliver(entry) end)
      %{entry | remaining: remaining, status: :started}
    else
      %{entry | remaining: remaining}
    end
  end

  defp apply_receipt(entry, _text, _failure), do: %{entry | status: :failed}

  defp synthesize_and_deliver(%{intent: intent, config: config, opts: opts}) do
    synthesize = Keyword.get(opts, :synthesize, &VoiceReply.synthesize/3)
    enqueue = Keyword.get(opts, :enqueue, &Outbox.enqueue/1)

    context = %{
      run_id: intent.run_id,
      session_key: intent.session_key,
      delivery_id: intent.intent_id
    }

    case synthesize.(value(intent.body, :text), config, context) do
      {:ok, audio} ->
        route = intent.route

        enqueue.(%OutboundPayload{
          channel_id: route.channel_id,
          account_id: route.account_id,
          peer: %{kind: route.peer_kind, id: route.peer_id, thread_id: route.thread_id},
          kind: :voice,
          content: audio,
          idempotency_key: "#{intent.intent_id}:voice",
          reply_to: value(intent.meta, :user_msg_id),
          meta: %{run_id: intent.run_id, session_key: intent.session_key}
        })

      {:error, _} ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp identity(intent) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({intent.run_id, intent.route, :answer}))
    "voice-final:" <> Base.url_encode64(digest, padding: false)
  end

  defp transcript_text(%OutboundPayload{kind: :text, content: text}) when is_binary(text),
    do: text

  defp transcript_text(%OutboundPayload{kind: :edit, content: content}) when is_map(content),
    do: value(content, :text)

  defp transcript_text(_payload), do: nil

  defp eligible?(intent, config, supported?) do
    intent.kind in [:final_text, :stream_finalize] and
      value(intent.meta, :terminal_answer) != false and
      value(intent.meta, :inbound_voice) == true and
      value(config, :enabled) == true and supported? == true and
      is_binary(value(intent.body, :text)) and String.trim(value(intent.body, :text)) != ""
  end

  defp channel_config(intent) do
    section =
      Enum.find(LemonCore.Config.Gateway.Channel.ids(), fn id ->
        Atom.to_string(id) == intent.route.channel_id
      end)

    if section, do: GatewayConfig.get(section, %{}) |> value(:voice_replies), else: nil
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_, _), do: nil
end
