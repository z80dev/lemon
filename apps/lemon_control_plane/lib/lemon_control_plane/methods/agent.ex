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
        "model" => "openai:gpt-4.1",                 # Optional: model override
        "queue_mode" => "collect",                    # Optional: queue mode (collect, followup, steer, interrupt)
        "cwd" => "/path/to/project",                  # Optional: working directory
        "tool_policy" => %{...},                      # Optional: tool policy overrides
        "project_memory_capture" => false,            # Optional: skip auxiliary extraction for this invocation
        "idempotency_key" => "unique-key"             # Optional: for deduplication
      }

  ## Response

      %{
        "run_id" => "550e8400-e29b-41d4-a716-446655440000",
        "session_key" => "agent:default:main"
      }

  ## Unknown outcomes

  The run ID is fixed before the router is called. When the submission's
  outcome is unknown (the router call timed out or exited after the request
  reached it, or the router reported `:outcome_unknown`), the method fails with
  code `UNAVAILABLE` and details
  `%{"code" => "SUBMISSION_OUTCOME_UNKNOWN", "runId" => run_id, "retrySafe" => false}`:
  the run may still execute, so reconcile it with `runs.receipt.get` instead of
  resubmitting. With an `idempotency_key`, the key stays claimed by that run ID
  (it never expires); later requests with the key return the same receipt, or
  the run once its router receipt shows it was accepted.

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
  alias LemonCore.{RunRequest, ToolPolicy}
  @legacy_selector_fields ~w(
    engine
    engine_id
    engineId
    default_engine
    defaultEngine
    engine_preference
    enginePreference
    preferred_engine
    preferredEngine
  )

  @impl true
  def name, do: "agent"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, ctx) do
    with :ok <- reject_legacy_selector(params),
         {:ok, validated} <- validate_params(params),
         {:ok, result} <- submit_run(validated, ctx) do
      {:ok, Map.put(result, "summary", summary(validated, result))}
    end
  end

  defp summary(params, result) do
    %{
      "agentId" => params.agent_id,
      "sessionKey" => result["session_key"],
      "runId" => result["run_id"],
      "queueMode" => to_string(params.queue_mode),
      "promptBytes" => byte_size(params.prompt),
      "hasCwd" => present?(params.cwd),
      "hasModelOverride" => present?(params.model),
      "hasToolPolicy" => is_map(params.tool_policy) and map_size(params.tool_policy) > 0,
      "hasIdempotencyKey" => present?(params.idempotency_key),
      "cleanup" => %{
        "includesPromptText" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp reject_legacy_selector(params) when is_map(params) do
    case Enum.filter(@legacy_selector_fields, &Map.has_key?(params, &1)) do
      [] ->
        :ok

      fields ->
        {:error,
         Errors.invalid_params(
           "Top-level engine selection is no longer supported; remove #{Enum.join(fields, ", ")}. Lemon now runs natively; use model to choose a model.",
           %{fields: fields}
         )}
    end
  end

  defp reject_legacy_selector(_), do: :ok

  defp validate_params(nil) do
    {:error, Errors.invalid_params("params is required")}
  end

  defp validate_params(params) when is_map(params) do
    case Map.get(params, "prompt") do
      nil ->
        {:error, Errors.invalid_params("prompt is required")}

      prompt when is_binary(prompt) and byte_size(prompt) > 0 ->
        with :ok <- validate_context_options(params),
             :ok <- validate_session_key(Map.get(params, "session_key")),
             {:ok, tool_policy} <- parse_optional_tool_policy(Map.get(params, "tool_policy")),
             :ok <- validate_project_memory_capture(params) do
          {:ok,
           %{
             prompt: prompt,
             agent_id: Map.get(params, "agent_id", "default"),
             session_key: Map.get(params, "session_key"),
             model: Map.get(params, "model"),
             queue_mode: parse_queue_mode(Map.get(params, "queue_mode")),
             cwd: Map.get(params, "cwd"),
             tool_policy: tool_policy,
             project_memory_capture: Map.get(params, "project_memory_capture", true),
             session_mode: Map.get(params, "session_mode"),
             persona: Map.get(params, "persona"),
             idempotency_key: Map.get(params, "idempotency_key")
           }}
        end

      _ ->
        {:error, Errors.invalid_params("prompt must be a non-empty string")}
    end
  end

  defp validate_params(_) do
    {:error, Errors.invalid_params("params must be an object")}
  end

  defp validate_project_memory_capture(params) do
    if is_boolean(Map.get(params, "project_memory_capture", true)),
      do: :ok,
      else: {:error, Errors.invalid_params("project_memory_capture must be a boolean")}
  end

  defp validate_context_options(params) do
    if Map.get(params, "session_mode") in [nil, "coding", "chat"] and
         Map.get(params, "persona") in [nil, true, false],
       do: :ok,
       else:
         {:error, Errors.invalid_params("session_mode must be coding|chat and persona a boolean")}
  end

  # The router owns the session under this key; an empty, blank or malformed
  # key is refused here, before any run ID or admission row exists.
  defp validate_session_key(nil), do: :ok

  defp validate_session_key(key) when is_binary(key) and byte_size(key) in 1..1024 do
    if String.valid?(key) and String.trim(key) != "" and not String.match?(key, ~r/[[:cntrl:]]/u),
      do: :ok,
      else: invalid_session_key()
  end

  defp validate_session_key(_key), do: invalid_session_key()

  defp invalid_session_key do
    {:error,
     Errors.invalid_params(
       "session_key must be a nonblank string of at most 1024 bytes without control characters"
     )}
  end

  defp parse_optional_tool_policy(nil), do: {:ok, nil}

  defp parse_optional_tool_policy(policy) do
    case ToolPolicy.parse(policy) do
      {:ok, policy} -> {:ok, policy}
      {:error, _reason} -> {:error, Errors.invalid_params("tool_policy is invalid")}
    end
  end

  defp parse_queue_mode("collect"), do: :collect
  defp parse_queue_mode("followup"), do: :followup
  defp parse_queue_mode("steer"), do: :steer
  defp parse_queue_mode("steer_backlog"), do: :steer_backlog
  defp parse_queue_mode("redirect"), do: :redirect
  defp parse_queue_mode("interrupt"), do: :interrupt
  defp parse_queue_mode(_), do: :collect

  defp submit_run(params, ctx) do
    # Generate session key if not provided
    session_key = params.session_key || generate_session_key(params.agent_id)

    case params.idempotency_key do
      nil ->
        case submit_via_router(params, session_key, LemonCore.Id.run_id(), ctx) do
          {:ok, _result} = ok -> ok
          {:error, _outcome, error} -> {:error, error}
        end

      key ->
        submit_once(key, params, session_key, ctx)
    end
  end

  # The key is claimed atomically before the router is called, so concurrent
  # requests submit once. The claim carries the fixed run ID and never expires:
  # an unknown router outcome keeps it, and every later request with the key
  # gets that run ID back instead of a second submission until the router's
  # receipt proves the run was admitted or aborted before dispatch.
  defp submit_once(key, params, session_key, ctx) do
    run_id = LemonCore.Id.run_id()
    pending = %{"run_id" => run_id, "session_key" => session_key}

    case LemonCore.Idempotency.begin(:agent, key, pending) do
      {:new, claim} ->
        case submit_via_router(params, session_key, run_id, ctx) do
          {:ok, result} ->
            _ = LemonCore.Idempotency.complete(claim, result)
            {:ok, result}

          {:error, :outcome_unknown, error} ->
            {:error, error}

          {:error, :rejected, error} ->
            _ = LemonCore.Idempotency.release(claim)
            {:error, error}
        end

      {:done, result} ->
        {:ok, result}

      {:pending, claim} ->
        reconcile(claim)

      {:error, :store_unavailable} ->
        {:error,
         Errors.unavailable("Idempotency state is unavailable; the run was not submitted")}
    end
  end

  # Resolves an earlier request's claim from the router's durable receipt for
  # its fixed run ID. Anything short of proof leaves the claim pending.
  defp reconcile(claim) do
    {run_id, session_key} =
      case LemonCore.Idempotency.meta(claim) do
        %{"run_id" => run_id, "session_key" => session_key} when is_binary(run_id) ->
          {run_id, session_key}

        _ ->
          {nil, nil}
      end

    receipt = if run_id, do: LemonCore.RouterBridge.run_receipt(run_id), else: :unknown

    case receipt do
      {:ok, %{state: :accepted}} ->
        result = %{"run_id" => run_id, "session_key" => session_key}
        _ = LemonCore.Idempotency.complete(claim, result)
        {:ok, result}

      {:ok, %{state: :aborted}} ->
        retry_safe = LemonCore.Idempotency.release(claim) == :ok

        {:error,
         Errors.error(:conflict, "The earlier request was aborted before it ran", %{
           "code" => "SUBMISSION_ABORTED",
           "runId" => run_id,
           "sessionKey" => session_key,
           "retrySafe" => retry_safe
         })}

      _unproven ->
        {:error,
         outcome_unknown(
           "A request with this idempotency_key is in progress or its outcome is unknown",
           run_id,
           session_key
         )}
    end
  end

  defp submit_via_router(params, session_key, run_id, ctx) do
    submit_params =
      RunRequest.new(%{
        origin: :control_plane,
        run_id: run_id,
        session_key: session_key,
        agent_id: params.agent_id,
        prompt: params.prompt,
        queue_mode: params.queue_mode,
        model: params.model,
        cwd: params.cwd,
        tool_policy: params.tool_policy,
        meta: %{
          origin: :control_plane,
          project_memory_capture: params.project_memory_capture,
          conn_id: ctx[:conn_id],
          conn_pid: ctx[:conn_pid],
          session_mode: params.session_mode,
          persona: params.persona
        }
      })

    case router_submit(submit_params) do
      {:ok, run_id} ->
        {:ok, %{"run_id" => run_id, "session_key" => session_key}}

      {:error, :outcome_unknown} ->
        {:error, :outcome_unknown,
         outcome_unknown("Run submission outcome is unknown", run_id, session_key)}

      {:error, :invalid_submission} ->
        {:error, :rejected, Errors.invalid_params("Run submission is invalid")}

      {:error, _reason} ->
        {:error, :rejected, Errors.internal_error("Failed to submit run")}
    end
  end

  # A call that exits after reaching the orchestrator (timeout, crash, lost
  # reply) may still have queued the run, so only a missing orchestrator is a
  # definite rejection.
  defp router_submit(request) do
    LemonRouter.submit(request)
  catch
    :exit, {:noproc, _} -> {:error, :router_unavailable}
    :exit, _uncertain -> {:error, :outcome_unknown}
  end

  defp outcome_unknown(message, run_id, session_key) do
    Errors.error(:unavailable, message, %{
      "code" => "SUBMISSION_OUTCOME_UNKNOWN",
      "runId" => run_id,
      "sessionKey" => session_key,
      "retrySafe" => false
    })
  end

  defp generate_session_key(agent_id) do
    "agent:#{agent_id}:main"
  end
end
