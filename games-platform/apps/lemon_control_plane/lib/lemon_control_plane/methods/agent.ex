defmodule LemonControlPlane.Methods.Agent do
  @moduledoc """
  Agent method for submitting runs.

  This method submits a new agent run through the router and returns the run ID.
  The caller can then subscribe to run events or use `agent.wait` to wait for completion.

  Requires `write` scope.

  ## Parameters

      %{
        "prompt" => "What is the weather?",           # Required: the prompt text
        "agent_id" => "default",                      # Optional: agent ID (default: "default")
        "session_key" => "agent:default:main",        # Optional: session key (auto-generated if not provided)
        "engine_id" => "claude",                      # Optional: engine override
        "model" => "openai:gpt-4.1",                 # Optional: model override
        "queue_mode" => "collect",                    # Optional: queue mode (collect, followup, steer, interrupt)
        "cwd" => "/path/to/project",                  # Optional: working directory
        "tool_policy" => %{...},                      # Optional: tool policy overrides
        "idempotency_key" => "unique-key"             # Optional: for deduplication
      }

  ## Response

      %{
        "run_id" => "550e8400-e29b-41d4-a716-446655440000",
        "session_key" => "agent:default:main"
      }

  ## Events

  After submitting, the connection will receive events for the run:

  - `agent` event with `type: "started"` when run begins
  - `agent` event with `type: "delta"` for streaming updates
  - `agent` event with `type: "tool_use"` for tool calls
  - `agent` event with `type: "completed"` when run finishes
  - `agent` event with `type: "error"` if run fails
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.RunRequest

  @impl true
  def name, do: "agent"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, ctx) do
    with {:ok, validated} <- validate_params(params),
         {:ok, result} <- submit_run(validated, ctx) do
      {:ok, result}
    end
  end

  defp validate_params(nil) do
    {:error, Errors.invalid_params("params is required")}
  end

  defp validate_params(params) when is_map(params) do
    case Map.get(params, "prompt") do
      nil ->
        {:error, Errors.invalid_params("prompt is required")}

      prompt when is_binary(prompt) and byte_size(prompt) > 0 ->
        {:ok,
         %{
           prompt: prompt,
           agent_id: Map.get(params, "agent_id", "default"),
           session_key: Map.get(params, "session_key"),
           engine_id: Map.get(params, "engine_id"),
           model: Map.get(params, "model"),
           queue_mode: parse_queue_mode(Map.get(params, "queue_mode")),
           cwd: Map.get(params, "cwd"),
           tool_policy: Map.get(params, "tool_policy"),
           idempotency_key: Map.get(params, "idempotency_key")
         }}

      _ ->
        {:error, Errors.invalid_params("prompt must be a non-empty string")}
    end
  end

  defp validate_params(_) do
    {:error, Errors.invalid_params("params must be an object")}
  end

  defp parse_queue_mode("collect"), do: :collect
  defp parse_queue_mode("followup"), do: :followup
  defp parse_queue_mode("steer"), do: :steer
  defp parse_queue_mode("steer_backlog"), do: :steer_backlog
  defp parse_queue_mode("interrupt"), do: :interrupt
  defp parse_queue_mode(_), do: :collect

  defp submit_run(params, ctx) do
    # Generate session key if not provided
    session_key = params.session_key || generate_session_key(params.agent_id)

    # Check for idempotency
    case check_idempotency(params.idempotency_key) do
      {:ok, :new} ->
        do_submit_run(params, session_key, ctx)

      {:ok, {:existing, result}} ->
        {:ok, result}
    end
  end

  defp do_submit_run(params, session_key, ctx) do
    # Try to submit through LemonRouter if available
    case Code.ensure_loaded(LemonRouter.RunOrchestrator) do
      {:module, _} ->
        submit_via_router(params, session_key, ctx)

      _ ->
        # Fallback: return a stub run_id for testing
        run_id = generate_run_id()

        result = %{
          "run_id" => run_id,
          "session_key" => session_key
        }

        # Store for idempotency
        store_idempotency(params.idempotency_key, result)

        {:ok, result}
    end
  end

  defp submit_via_router(params, session_key, ctx) do
    submit_params =
      RunRequest.new(%{
        origin: :control_plane,
        session_key: session_key,
        agent_id: params.agent_id,
        prompt: params.prompt,
        queue_mode: params.queue_mode,
        engine_id: params.engine_id,
        model: params.model,
        cwd: params.cwd,
        tool_policy: params.tool_policy,
        meta: %{
          origin: :control_plane,
          conn_id: ctx[:conn_id],
          conn_pid: ctx[:conn_pid]
        }
      })

    case LemonRouter.RunOrchestrator.submit(submit_params) do
      {:ok, run_id} ->
        result = %{
          "run_id" => run_id,
          "session_key" => session_key
        }

        # Store for idempotency
        store_idempotency(params.idempotency_key, result)

        {:ok, result}

      {:error, reason} ->
        {:error, Errors.internal_error("Failed to submit run", inspect(reason))}
    end
  end

  defp generate_session_key(agent_id) do
    "agent:#{agent_id}:main"
  end

  defp generate_run_id do
    UUID.uuid4()
  end

  defp check_idempotency(nil), do: {:ok, :new}

  defp check_idempotency(key) do
    case Code.ensure_loaded(LemonCore.Idempotency) do
      {:module, _} ->
        case LemonCore.Idempotency.get(:agent, key) do
          {:ok, result} -> {:ok, {:existing, result}}
          :miss -> {:ok, :new}
        end

      _ ->
        {:ok, :new}
    end
  end

  defp store_idempotency(nil, _result), do: :ok

  defp store_idempotency(key, result) do
    case Code.ensure_loaded(LemonCore.Idempotency) do
      {:module, _} ->
        LemonCore.Idempotency.put(:agent, key, result)

      _ ->
        :ok
    end
  end
end
