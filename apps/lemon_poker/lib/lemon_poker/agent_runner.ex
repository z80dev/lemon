defmodule LemonPoker.AgentRunner do
  @moduledoc """
  Thin wrapper for running a single Lemon agent prompt and waiting for completion.
  """

  alias LemonCore.{Bus, Event}

  @default_timeout_ms 90_000

  @type run_ok :: %{run_id: String.t(), answer: String.t()}
  @type run_error :: {:run_failed, term(), String.t() | nil}

  @spec run_prompt(String.t(), String.t(), keyword()) ::
          {:ok, run_ok()} | {:error, :timeout | run_error() | term()}
  def run_prompt(session_key, prompt, opts \\ [])
      when is_binary(session_key) and is_binary(prompt) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    params =
      %{
        origin: Keyword.get(opts, :origin, :poker),
        session_key: session_key,
        agent_id: Keyword.get(opts, :agent_id, "default"),
        prompt: prompt,
        meta: Keyword.get(opts, :meta, %{})
      }
      |> maybe_put(:engine_id, Keyword.get(opts, :engine_id))
      |> maybe_put(:cwd, Keyword.get(opts, :cwd))
      |> maybe_put(:tool_policy, Keyword.get(opts, :tool_policy))

    case LemonRouter.submit(params) do
      {:ok, run_id} when is_binary(run_id) ->
        wait_for_run(run_id, timeout_ms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec wait_for_run(String.t(), non_neg_integer()) ::
          {:ok, run_ok()} | {:error, :timeout | run_error()}
  def wait_for_run(run_id, timeout_ms \\ @default_timeout_ms)
      when is_binary(run_id) and is_integer(timeout_ms) and timeout_ms > 0 do
    topic = Bus.run_topic(run_id)
    :ok = Bus.subscribe(topic)

    try do
      receive do
        %Event{type: :run_completed, payload: payload} ->
          to_run_result(run_id, payload)

        %{type: :run_completed, payload: payload} ->
          to_run_result(run_id, payload)
      after
        timeout_ms ->
          {:error, :timeout}
      end
    after
      Bus.unsubscribe(topic)
    end
  end

  defp to_run_result(run_id, payload) do
    completed = fetch(payload, :completed) || payload
    ok? = fetch(completed, :ok) == true
    answer = fetch(completed, :answer)
    error = fetch(completed, :error)

    if ok? do
      {:ok, %{run_id: run_id, answer: normalize_answer(answer)}}
    else
      {:error, {:run_failed, error, normalize_answer(answer)}}
    end
  end

  defp normalize_answer(answer) when is_binary(answer), do: answer
  defp normalize_answer(nil), do: ""
  defp normalize_answer(other), do: inspect(other)

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch(_, _), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
