defmodule LemonControlPlane.Methods.LearnSupport do
  @moduledoc false

  alias LemonControlPlane.Protocol.Errors

  def opts(params) do
    configured = Application.get_env(:lemon_control_plane, :learn_opts, [])

    configured
    |> put(:root, params["root"])
    |> put(:agent_id, params["agentId"])
    |> put(:session_key, params["sessionKey"])
    |> put(:global, params["project"] != true)
    |> put(:max_output_bytes, params["maxBytes"])
    |> put(:max_input_bytes, params["maxInputBytes"])
    |> put(:max_items, params["maxItems"])
    |> put(:max_pages, params["maxPages"])
    |> put(:max_depth, params["maxDepth"])
    |> put(:timeout_ms, params["timeoutMs"])
  end

  def result({:ok, payload}), do: {:ok, payload}

  def result({:error, {code, message}}) do
    protocol_code =
      cond do
        code in [:confirmation_mismatch, :conflict, :memory_collision, :skill_collision] ->
          :conflict

        code in [:memory_write_failed, :skill_write_failed, :draft_unavailable] ->
          :unavailable

        true ->
          :invalid_request
      end

    {:error, Errors.error(protocol_code, message)}
  end

  def result(_), do: {:error, Errors.internal_error("Learning operation failed")}

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)
end

defmodule LemonControlPlane.Methods.LearnReview do
  @moduledoc "Reviews bounded source-learning proposals without durable writes."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.LearnSupport

  @impl true
  def name, do: "learn.review"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params["references"]
    |> LemonSkills.Learn.review(LearnSupport.opts(params))
    |> LearnSupport.result()
  end
end

defmodule LemonControlPlane.Methods.LearnConfirm do
  @moduledoc "Confirms an exact fresh learning review and writes canonical memory and draft state."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.LearnSupport

  @impl true
  def name, do: "learn.confirm"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    params["references"]
    |> LemonSkills.Learn.confirm(params["confirmationDigest"], LearnSupport.opts(params))
    |> LearnSupport.result()
  end
end
