defmodule LemonAutomation.RunCompletionWaiter do
  @moduledoc false

  alias LemonCore.Events

  @default_timeout_ms 300_000
  @max_output_chars 1_000

  @type wait_result :: {:ok, binary()} | {:error, binary()} | :timeout

  @spec wait(binary(), non_neg_integer(), keyword()) :: wait_result()
  def wait(run_id, timeout_ms \\ @default_timeout_ms, opts \\ []) when is_binary(run_id) do
    bus_mod = Keyword.get(opts, :bus_mod, LemonCore.Bus)
    topic = "run:#{run_id}"

    bus_mod.subscribe(topic)

    try do
      do_wait(timeout_ms)
    after
      bus_mod.unsubscribe(topic)
    end
  end

  @doc """
  Wait for run completion when already subscribed to the bus topic.
  Used by RunSubmitter to avoid race condition where run completes
  before subscription.
  """
  @spec wait_already_subscribed(binary(), non_neg_integer(), keyword()) :: wait_result()
  def wait_already_subscribed(run_id, timeout_ms \\ @default_timeout_ms, opts \\ [])
      when is_binary(run_id) do
    bus_mod = Keyword.get(opts, :bus_mod, LemonCore.Bus)
    topic = "run:#{run_id}"

    # Caller is already subscribed, just wait and unsubscribe when done
    try do
      do_wait(timeout_ms)
    after
      bus_mod.unsubscribe(topic)
    end
  end

  # Shared wait logic.
  #
  # Both terminal events arrive as `LemonCore.Event` envelopes: since P1 (see
  # docs/platform/bus-events.md §8) no publisher in the umbrella emits either type without
  # one, so the envelope-less-map clauses that used to stand in for the pre-P1 `:run_failed`
  # are gone along with the `Access` shim they leaned on. The payload is coerced to its
  # `LemonCore.Events` struct on arrival, so a legacy map — the cron summary the automation
  # app forwards, or an injected event — is still read by field rather than by key.
  defp do_wait(timeout_ms) do
    receive do
      %LemonCore.Event{type: :run_completed, payload: payload} ->
        extract_output_from_completion(Events.coerce(:run_completed, payload))

      %LemonCore.Event{type: :run_failed, payload: payload} ->
        failure_reason(Events.coerce(:run_failed, payload))
    after
      timeout_ms ->
        :timeout
    end
  end

  defp failure_reason(%Events.RunFailed{reason: reason}), do: {:error, inspect(reason)}
  defp failure_reason(payload), do: {:error, inspect(payload)}

  @doc false
  @spec extract_output_from_completion(term()) :: {:ok, binary()} | {:error, binary()}
  def extract_output_from_completion(%Events.RunCompleted{completed: completed})
      when not is_nil(completed) do
    extract_output_from_completion(completed)
  end

  def extract_output_from_completion(%Events.Completion{ok: true, answer: answer}) do
    {:ok, truncate_output(answer)}
  end

  def extract_output_from_completion(%Events.Completion{ok: false, error: error}) do
    {:error, inspect(error)}
  end

  def extract_output_from_completion(%Events.Completion{answer: answer} = completion) do
    if is_binary(answer),
      do: {:ok, truncate_output(answer)},
      else: {:ok, truncate_output(inspect(completion))}
  end

  def extract_output_from_completion(%{completed: %{answer: answer, ok: true}}) do
    {:ok, truncate_output(answer)}
  end

  def extract_output_from_completion(%{completed: %{ok: false, error: error}}) do
    {:error, inspect(error)}
  end

  def extract_output_from_completion(%{answer: answer, ok: true}) do
    {:ok, truncate_output(answer)}
  end

  def extract_output_from_completion(%{ok: false, error: error}) do
    {:error, inspect(error)}
  end

  # Free-form legacy payloads only. Every payload struct has matched above, so the key reads
  # below are `Access` on a plain map — never on a `LemonCore.Events` struct.
  def extract_output_from_completion(result) when is_map(result) and not is_struct(result) do
    cond do
      is_binary(result[:output]) -> {:ok, truncate_output(result[:output])}
      is_binary(result["output"]) -> {:ok, truncate_output(result["output"])}
      is_binary(result[:answer]) -> {:ok, truncate_output(result[:answer])}
      is_binary(result["answer"]) -> {:ok, truncate_output(result["answer"])}
      true -> {:ok, truncate_output(inspect(result))}
    end
  end

  def extract_output_from_completion(result) do
    {:ok, truncate_output(inspect(result))}
  end

  defp truncate_output(text) when is_binary(text) do
    String.slice(text, 0, @max_output_chars)
  end

  defp truncate_output(text), do: inspect(text) |> String.slice(0, @max_output_chars)
end
