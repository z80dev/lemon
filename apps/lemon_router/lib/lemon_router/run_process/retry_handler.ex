defmodule LemonRouter.RunProcess.RetryHandler do
  @moduledoc """
  Zero-answer auto-retry logic for RunProcess.

  When a run completes with an error and no answer, this module decides
  whether an automatic retry is warranted and, if so, builds and submits
  a new RunRequest through the RunOrchestrator.
  """

  require Logger

  alias LemonCore.{RunRequest, SessionKey}
  alias LemonRouter.RunProcess.CompactionTrigger

  @zero_answer_retry_max_attempts 1
  @zero_answer_retry_prefix """
  Retry notice: the previous attempt failed before producing an answer.
  Before taking new actions, first check for partially completed work from the prior attempt and continue from current state instead of repeating completed steps.
  """

  @doc """
  Attempt an auto-retry of a failed run that produced no answer.

  Returns `true` if a retry was submitted, `false` otherwise.
  """
  @spec maybe_retry_zero_answer_failure(map(), LemonCore.Event.t()) :: boolean()
  def maybe_retry_zero_answer_failure(state, %LemonCore.Event{} = event) do
    with {:retry, %RunRequest{} = request, error_text, attempt} <-
           build_zero_answer_retry_request(state, event),
         {:ok, retry_run_id} <- submit_retry_request(state.run_orchestrator, request) do
      Logger.warning(
        "RunProcess #{state.run_id} auto-retrying empty-answer failure " <>
          "(attempt=#{attempt}/#{@zero_answer_retry_max_attempts}) " <>
          "new_run_id=#{inspect(retry_run_id)} reason=#{error_text}"
      )

      true
    else
      :skip ->
        false

      {:error, reason} ->
        Logger.warning(
          "RunProcess #{state.run_id} auto-retry submission failed: #{inspect(reason)}"
        )

        false
    end
  rescue
    error ->
      Logger.warning("RunProcess #{state.run_id} auto-retry crashed: #{Exception.message(error)}")

      false
  end

  @doc """
  Format a run error as a human-readable string.
  """
  @spec format_run_error(term()) :: String.t()
  def format_run_error(nil), do: "unknown error"

  def format_run_error({:assistant_error, msg}) when is_binary(msg),
    do: format_assistant_error(msg)

  def format_run_error({:assistant_error, reason}), do: "assistant error: #{inspect(reason)}"
  def format_run_error(e) when is_binary(e), do: e
  def format_run_error(e) when is_atom(e), do: Atom.to_string(e)
  def format_run_error(e), do: inspect(e)

  # ---- Private helpers ----

  defp build_zero_answer_retry_request(state, %LemonCore.Event{} = event) do
    {ok?, error} = CompactionTrigger.extract_completed_ok_and_error(event)
    answer = CompactionTrigger.extract_completed_answer(event)
    meta = normalize_retry_meta(state.job.meta)
    prior_attempt = retry_attempt_from_meta(meta)
    prompt = state.job.prompt

    cond do
      ok? == true ->
        :skip

      not empty_answer?(answer) ->
        :skip

      not retryable_zero_answer_error?(error) ->
        :skip

      not (is_binary(prompt) and String.trim(prompt) != "") ->
        :skip

      prior_attempt >= @zero_answer_retry_max_attempts ->
        :skip

      true ->
        attempt = prior_attempt + 1
        reason_text = format_run_error(error)

        retry_meta =
          meta
          |> Map.put(:zero_answer_retry_attempt, attempt)
          |> Map.put(:zero_answer_retry_of_run, state.run_id)
          |> Map.put(:zero_answer_retry_reason, reason_text)

        retry_prompt = build_zero_answer_retry_prompt(prompt, state.run_id, reason_text)

        request =
          RunRequest.new(%{
            origin: retry_origin_from_meta(meta),
            session_key: state.session_key,
            agent_id: SessionKey.agent_id(state.session_key || "") || "default",
            prompt: retry_prompt,
            queue_mode: state.job.queue_mode,
            engine_id: state.job.engine_id,
            cwd: state.job.cwd,
            tool_policy: state.job.tool_policy,
            meta: retry_meta
          })

        {:retry, request, reason_text, attempt}
    end
  end

  defp submit_retry_request(run_orchestrator, %RunRequest{} = request) do
    cond do
      function_exported?(run_orchestrator, :submit, 1) ->
        run_orchestrator.submit(request)

      function_exported?(run_orchestrator, :submit_run, 1) ->
        run_orchestrator.submit_run(request)

      true ->
        {:error, :run_orchestrator_unavailable}
    end
  end

  defp normalize_retry_meta(meta) when is_map(meta), do: meta
  defp normalize_retry_meta(_), do: %{}

  defp retry_attempt_from_meta(meta) when is_map(meta) do
    case fetch(meta, :zero_answer_retry_attempt) do
      attempt when is_integer(attempt) and attempt >= 0 -> attempt
      _ -> 0
    end
  end

  defp retry_origin_from_meta(meta) when is_map(meta) do
    fetch(meta, :origin) || :unknown
  end

  defp empty_answer?(answer) when is_binary(answer), do: String.trim(answer) == ""
  defp empty_answer?(_), do: true

  defp retryable_zero_answer_error?(error)
       when error in [:user_requested, :interrupted, :new_session, :timeout],
       do: false

  defp retryable_zero_answer_error?({:assistant_error, reason}) do
    not CompactionTrigger.context_length_exceeded_error?(reason)
  end

  defp retryable_zero_answer_error?(error) when is_binary(error) do
    down = String.downcase(error)

    (String.contains?(down, "assistant_error") or String.contains?(down, "assistant error")) and
      not CompactionTrigger.context_length_exceeded_error?(error)
  end

  defp retryable_zero_answer_error?(error) when is_map(error) do
    text = error |> inspect(limit: 50, printable_limit: 2_000) |> String.downcase()

    (String.contains?(text, "assistant_error") or String.contains?(text, "assistant error")) and
      not CompactionTrigger.context_length_exceeded_error?(error)
  end

  defp retryable_zero_answer_error?(_), do: false

  defp build_zero_answer_retry_prompt(prompt, failed_run_id, reason_text)
       when is_binary(prompt) and is_binary(reason_text) do
    @zero_answer_retry_prefix <>
      "\nPrevious run: #{failed_run_id}\nFailure: #{reason_text}\n\n" <>
      "Original request:\n" <>
      prompt
  end

  defp format_assistant_error(msg) when is_binary(msg) do
    down = String.downcase(msg)

    cond do
      String.contains?(down, "bad_record_mac") or
          (String.contains?(down, "req.transporterror") and String.contains?(down, "tls_alert")) ->
        "temporary TLS/network error while contacting the model provider; please retry"

      true ->
        msg
    end
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_, _), do: nil
end
