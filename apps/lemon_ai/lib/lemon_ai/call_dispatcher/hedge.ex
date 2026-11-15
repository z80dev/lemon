defmodule LemonAi.CallDispatcher.Hedge do
  @moduledoc false

  alias LemonAi.{CallDispatcher, EventStream}
  alias LemonAi.Types.{AssistantMessage, Usage}

  def start(primary, provider, callback, opts, key, deadline) do
    {:ok, output} = EventStream.start_link()

    case Task.Supervisor.start_child(LemonAi.StreamTaskSupervisor, fn ->
           run(primary, output, provider, callback, opts, key, deadline)
         end) do
      {:ok, worker} ->
        EventStream.attach_task(output, worker)
        # The primary was created by the dispatch caller, not this worker. Its
        # owner monitor alone cannot cancel it when the output is abandoned.
        Task.Supervisor.start_child(LemonAi.StreamTaskSupervisor, fn ->
          monitor = Process.monitor(worker)

          receive do
            {:DOWN, ^monitor, :process, ^worker, _} ->
              EventStream.cancel(primary, :hedge_finished)
          end
        end)

        {:ok, output}

      {:error, _} ->
        EventStream.cancel(output, :hedge_unavailable)
        {:ok, primary}
    end
  end

  defp run(primary, output, provider, callback, opts, key, deadline) do
    {:ok, primary_ref} = EventStream.subscribe_result(primary, self(), first_event: true)

    {winner, loser, tokens} =
      receive do
        {:event_stream_first_event, ^primary_ref, _} -> {primary, nil, 0}
        {:event_stream_result, ^primary_ref, _} -> {primary, nil, 0}
      after
        deadline -> race(primary, primary_ref, provider, callback, opts, key)
      end

    if loser, do: EventStream.cancel(loser, :hedge_lost)
    relay(winner, output, tokens)
  rescue
    _ -> EventStream.cancel(output, :hedge_failed)
  after
    EventStream.cancel(primary, :hedge_finished)
  end

  defp race(primary, primary_ref, provider, callback, opts, key) do
    # A first-event notification already in the mailbox wins before admission.
    receive do
      {:event_stream_first_event, ^primary_ref, _} -> {primary, nil, 0}
      {:event_stream_result, ^primary_ref, _} -> {primary, nil, 0}
    after
      0 ->
        if CallDispatcher.hedge_claim(key) do
          launch(primary, primary_ref, provider, callback, opts, key)
        else
          :telemetry.execute([:lemon_ai, :dispatcher, :hedge_skipped], %{}, %{
            provider: provider,
            model: elem(key, 1),
            reason: :budget_exhausted
          })

          {primary, nil, 0}
        end
    end
  end

  defp launch(primary, primary_ref, provider, callback, opts, key) do
    duplicate_opts =
      opts |> Keyword.put(:queue_timeout_ms, 0) |> Keyword.put(:hedge_attempt, true)

    token_estimate = Keyword.get(opts, :hedge_input_tokens, fn -> 0 end)
    tokens = token_estimate.()
    admitted_ref = make_ref()

    duplicate_callback = fn ->
      :ok = CallDispatcher.hedge_charge(key, tokens)
      send(self(), admitted_ref)

      :telemetry.execute(
        [:lemon_ai, :dispatcher, :hedge_started],
        %{duplicate_input_tokens: tokens},
        %{provider: provider, model: elem(key, 1)}
      )

      callback.()
    end

    result =
      try do
        CallDispatcher.dispatch(provider, duplicate_callback, duplicate_opts)
      catch
        _, _ -> {:error, :hedge_callback_failed}
      end

    admitted? =
      receive do
        ^admitted_ref -> true
      after
        0 -> false
      end

    case result do
      {:ok, duplicate} when is_pid(duplicate) ->
        {:ok, duplicate_ref} = EventStream.subscribe_result(duplicate, self(), first_event: true)

        receive do
          {:event_stream_first_event, ^primary_ref, _} -> {primary, duplicate, tokens}
          {:event_stream_result, ^primary_ref, _} -> {primary, duplicate, tokens}
          {:event_stream_first_event, ^duplicate_ref, _} -> {duplicate, primary, tokens}
          {:event_stream_result, ^duplicate_ref, _} -> {duplicate, primary, tokens}
        end

      {:error, reason} ->
        unless admitted?, do: CallDispatcher.hedge_refund(key)

        :telemetry.execute([:lemon_ai, :dispatcher, :hedge_skipped], %{}, %{
          provider: provider,
          model: elem(key, 1),
          reason: reason
        })

        {primary, nil, if(admitted?, do: tokens, else: 0)}
    end
  end

  defp relay(winner, output, tokens) do
    try do
      winner
      |> EventStream.events()
      |> Enum.reduce_while(:ok, fn
        {:done, _reason, message}, _ ->
          EventStream.complete(output, charge(message, tokens))
          {:halt, :ok}

        {:error, _reason, message}, _ ->
          EventStream.error(output, charge(message, tokens))
          {:halt, :ok}

        {:canceled, reason}, _ ->
          EventStream.cancel(output, reason)
          {:halt, :ok}

        event, _ ->
          case EventStream.push(output, event) do
            :ok -> {:cont, :ok}
            {:error, _} -> {:halt, :ok}
          end
      end)
    after
      EventStream.cancel(winner, :hedge_finished)
    end
  end

  defp charge(%AssistantMessage{usage: %Usage{} = usage} = message, tokens) do
    %{
      message
      | usage: %{
          usage
          | input: add_known(usage.input, tokens),
            total_tokens: add_known(usage.total_tokens, tokens)
        }
    }
  end

  defp charge(message, _tokens), do: message

  defp add_known(nil, _tokens), do: nil
  defp add_known(value, tokens), do: value + tokens
end
