defmodule LemonAutomation.RunCompletionWaiter do
  @moduledoc false

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
  # Both terminal events arrive as `LemonCore.Event` envelopes. The bare-map clauses accept a
  # payload published without an envelope, which Phase 3.1 kept for one deprecation cycle;
  # the tuple and envelope-less `%{completed: ...}` clauses that used to live here matched
  # shapes no publisher in the umbrella could produce and are gone.
  defp do_wait(timeout_ms) do
    receive do
      %LemonCore.Event{type: :run_completed, payload: payload} ->
        extract_output_from_completion(payload)

      %LemonCore.Event{type: :run_failed, payload: payload} ->
        {:error, inspect(payload[:reason] || payload)}

      %{type: :run_completed, payload: payload} ->
        extract_output_from_completion(payload)

      %{type: :run_failed, payload: payload} ->
        {:error, inspect(payload[:reason] || payload)}
    after
      timeout_ms ->
        :timeout
    end
  end

  @doc false
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

  def extract_output_from_completion(result) when is_map(result) do
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
