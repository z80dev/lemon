defmodule LemonAi.OneshotRetry do
  @moduledoc """
  Bounded transient-error recovery for side-effect-free completions.

  `run/2` invokes a completion callback with a one-based attempt number. It
  accepts a resolved `AssistantMessage`, `{:ok, message}` or `{:error, reason}`
  and preserves the final result's shape. Only `LemonAi.Error.retryable?/1`
  failures replay; authentication, client, quota and context-overflow failures
  surface unchanged. Do not wrap streaming callbacks or tool execution here.

  Options (keyword list or map) are local to the call:

    * `:max_attempts` — total attempts, including the first (default 3).
    * `:base_delay_ms` — initial jittered backoff (default 500).
    * `:max_delay_ms` — maximum single wait (default 30,000). Longer server
      hints surface the failure unchanged, never retry earlier than requested.
    * `:sleep_fun` — injected one-argument wait, returning `:ok` or
      `{:error, cancellation_reason}`. Custom waits own their responsiveness.
    * `:cancelled?` — zero-argument cancellation predicate (default false).
      The default wait polls it every 50ms. Cancellation already visible when
      an attempt settles preserves its result; cancellation during a wait
      returns `{:error, :aborted}` (or the injected wait's cancellation reason).

  In-flight cancellation belongs to the completion callback: construct any
  per-attempt deadline inside it rather than sharing an expired deadline.
  """

  alias LemonAi.Error
  alias LemonAi.Providers.RetryHelper
  alias LemonAi.Types.AssistantMessage

  @spec run((pos_integer() -> term()), keyword() | map()) :: term()
  def run(complete, options \\ []) when is_function(complete, 1) do
    options = Map.new(options)

    policy = %{
      max_attempts: max(1, Map.get(options, :max_attempts, 3)),
      base_delay_ms: max(1, Map.get(options, :base_delay_ms, 500)),
      max_delay_ms: max(0, Map.get(options, :max_delay_ms, 30_000))
    }

    attempt(complete, options, policy, 1)
  end

  defp attempt(complete, options, policy, number) do
    if cancelled?(options) do
      {:error, :aborted}
    else
      result = complete.(number)

      case failure(result) do
        {:failed, error} ->
          cond do
            cancelled?(options) -> result
            number >= policy.max_attempts -> result
            not Error.retryable?(error) -> result
            true ->
              case RetryHelper.error_retry_after_ms(error) do
                hint when is_integer(hint) and hint > policy.max_delay_ms ->
                  result

                hint ->
                  delay =
                    hint ||
                      min(RetryHelper.backoff_delay_ms(number - 1, policy), policy.max_delay_ms)

                  case sleep(delay, options) do
                    :ok -> attempt(complete, options, policy, number + 1)
                    {:error, _reason} = canceled -> canceled
                  end
              end
          end

        :success ->
          result
      end
    end
  end

  defp failure(%AssistantMessage{stop_reason: :error} = message), do: {:failed, message}
  defp failure({:ok, %AssistantMessage{stop_reason: :error} = message}), do: {:failed, message}
  defp failure({:error, %AssistantMessage{stop_reason: reason}}) when reason in [:aborted, :redirected],
    do: :success
  defp failure({:error, reason}), do: {:failed, reason}
  defp failure(_result), do: :success

  defp cancelled?(options), do: Map.get(options, :cancelled?, fn -> false end).()

  defp sleep(delay, options) do
    case Map.get(options, :sleep_fun) do
      nil -> wait(System.monotonic_time(:millisecond) + delay, options)
      sleep_fun ->
        case sleep_fun.(delay) do
          {:error, _reason} = canceled -> canceled
          _ -> if cancelled?(options), do: {:error, :aborted}, else: :ok
        end
    end
  end

  defp wait(deadline, options) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      cancelled?(options) -> {:error, :aborted}
      remaining <= 0 -> :ok
      true ->
        Process.sleep(min(remaining, 50))
        wait(deadline, options)
    end
  end
end
