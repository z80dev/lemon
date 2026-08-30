defmodule LemonAutomation.RunCompletionWaiter do
  @moduledoc """
  Owns the race-free submit-and-wait lifecycle for automation router runs.

  `submit_and_wait/2` assigns a fixed run id, subscribes to that run topic before
  calling the router, waits for a terminal event, and always removes the
  subscription. Callers that need completion must use this primitive instead of
  submitting first and subscribing afterwards; a router run may complete
  synchronously during `submit/1`.

  Lifecycle owners may install an `:on_submitting` claim callback. It runs with
  the fixed run ID before router submission and must return `:ok`; rejecting the
  claim prevents submission. This lets a hard-stop owner publish abort ownership
  before the router can accept the run, while retaining the pre-subscription
  guarantee for synchronous completion.

  The router is required to return the assigned run id. A different id is
  reported explicitly because subscribing to the replacement after submission
  would reintroduce the completion race.
  """

  alias LemonCore.Events

  @default_timeout_ms 300_000
  @max_output_chars 1_000

  @type wait_result :: {:ok, binary()} | {:error, binary()} | :timeout

  @type submit_result ::
          {:ok, binary(), binary()}
          | {:error, {:run_failed, binary(), term()}}
          | {:error, {:timeout, binary()}}
          | {:error, {:submit_failed, term()}}
          | {:error, {:unexpected_run_id, binary(), term()}}
          | {:error, {:unexpected_wait_result, binary(), term()}}

  @doc """
  Submit a router run and wait for its terminal event without a subscription gap.

  Options:

    * `:router_mod` - module implementing `submit/1`
    * `:waiter_mod` - module implementing `wait_already_subscribed/3`
    * `:bus_mod` - bus module implementing `subscribe/1` and `unsubscribe/1`
    * `:timeout_ms` - terminal wait timeout
    * `:wait_opts` - options forwarded to the waiter
    * `:on_submitting` - ownership claim invoked before router submission; it
      must return `:ok` or `{:error, reason}`
    * `:on_submitted` - callback invoked with the authoritative router run ID
    * `:on_terminal` - callback invoked with the same run ID after waiting

  Returns the fixed run id with successful output. Submission, timeout, run
  failure, mismatched-run-id, and unexpected waiter results remain distinct so
  lifecycle owners can persist the correct terminal state.
  """
  @spec submit_and_wait(map(), keyword()) :: submit_result()
  def submit_and_wait(params, opts \\ []) when is_map(params) do
    router_mod = Keyword.get(opts, :router_mod, LemonRouter)
    waiter_mod = Keyword.get(opts, :waiter_mod, __MODULE__)
    bus_mod = Keyword.get(opts, :bus_mod, LemonCore.Bus)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    wait_opts = Keyword.get(opts, :wait_opts, [])
    run_id = params[:run_id] || params["run_id"] || LemonCore.Id.run_id()
    params = params |> Map.delete("run_id") |> Map.put(:run_id, run_id)
    topic = run_topic(bus_mod, run_id)

    bus_mod.subscribe(topic)

    try do
      case claim_submission(Keyword.get(opts, :on_submitting), run_id) do
        :ok ->
          case safe_submit(router_mod, params) do
            {:ok, ^run_id} ->
              :ok = notify(Keyword.get(opts, :on_submitted), run_id)

              result =
                normalize_wait_result(
                  run_id,
                  waiter_mod.wait_already_subscribed(run_id, timeout_ms, wait_opts)
                )

              :ok = notify(Keyword.get(opts, :on_terminal), run_id)
              result

            {:ok, other_run_id} ->
              {:error, {:unexpected_run_id, run_id, other_run_id}}

            {:error, reason} ->
              {:error, {:submit_failed, reason}}

            other ->
              {:error, {:submit_failed, {:unexpected_submit_result, other}}}
          end

        {:error, reason} ->
          {:error, {:submit_failed, {:submission_claim_rejected, reason}}}
      end
    rescue
      error -> {:error, {:submit_failed, {:exception, error}}}
    catch
      :exit, reason -> {:error, {:submit_failed, {:exit, reason}}}
    after
      bus_mod.unsubscribe(topic)
    end
  end

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
  Wait for run completion when the caller already owns the bus subscription.

  This function does not unsubscribe. `submit_and_wait/2`, or another lifecycle
  owner, must remove the subscription in an `after` block.
  """
  @spec wait_already_subscribed(binary(), non_neg_integer(), keyword()) :: wait_result()
  def wait_already_subscribed(run_id, timeout_ms \\ @default_timeout_ms, opts \\ [])
      when is_binary(run_id) do
    _ = opts
    do_wait(timeout_ms)
  end

  defp safe_submit(router_mod, params) do
    router_mod.submit(params)
  rescue
    error -> {:error, {:exception, error}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp notify(nil, _run_id), do: :ok

  defp notify(callback, run_id) when is_function(callback, 1) do
    callback.(run_id)
    :ok
  end

  defp claim_submission(nil, _run_id), do: :ok

  defp claim_submission(callback, run_id) when is_function(callback, 1) do
    case callback.(run_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_claim_result, other}}
    end
  end

  defp normalize_wait_result(run_id, {:ok, output}), do: {:ok, run_id, output}
  defp normalize_wait_result(run_id, :timeout), do: {:error, {:timeout, run_id}}

  defp normalize_wait_result(run_id, {:error, reason}),
    do: {:error, {:run_failed, run_id, reason}}

  defp normalize_wait_result(run_id, other),
    do: {:error, {:unexpected_wait_result, run_id, other}}

  defp run_topic(bus_mod, run_id) do
    if function_exported?(bus_mod, :run_topic, 1) do
      bus_mod.run_topic(run_id)
    else
      "run:#{run_id}"
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
