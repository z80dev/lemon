defmodule LemonControlPlane.Methods.Agent do
  @moduledoc """
  Agent method for submitting runs.

  This method submits a new agent run through the router and returns its
  admission receipt. The caller can then subscribe to run events or use
  `agent.wait` to wait for completion.

  Requires `write` scope.

  ## Parameters

      %{
        "prompt" => "What is the weather?",      # Required: the prompt text
        "agentId" => "default",                  # Optional: agent or managed profile ID
        "sessionKey" => "agent:default:main",    # Optional: defaults to `agent:<agentId>:main`,
                                                 #   or a profile's canonical session
        "runId" => "run_...",                    # Optional: fixed run ID (generated once otherwise)
        "queueMode" => "collect",                # Optional: collect, followup, steer,
                                                 #   steer_backlog, redirect or interrupt
        "model" => "openai:gpt-4.1",             # Optional: model override
        "cwd" => "/path/to/project",             # Optional: absolute existing directory
        "tool_policy" => %{...},                 # Optional: restricts the effective policy
        "project_memory_capture" => false,       # Optional: skip auxiliary extraction
        "session_mode" => "coding",              # Optional: coding | chat
        "persona" => false,                      # Optional: boolean
        "idempotency_key" => "unique-key"        # Optional: for deduplication
      }

  The pre-camelCase spellings `session_key`, `agent_id` and `queue_mode` are
  rejected rather than ignored.

  An `agentId` naming a managed profile runs as that profile's chat, exactly
  like `chat.send` with `profileId`: in the profile's workspace and, without a
  `sessionKey`, its canonical session. A caller `cwd` is then rejected, as it is
  for any canonical profile session.

  ## Response

  The receipt shared with `chat.send` (`runId`, `sessionKey`, `state`,
  `effectiveMode`, `targetRunId`, `retrySafe: false`) plus a content-free
  `summary`.

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

  alias LemonControlPlane.ChatSubmission
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
  @renamed_fields %{
    "session_key" => "sessionKey",
    "agent_id" => "agentId",
    "queue_mode" => "queueMode"
  }
  @queue_modes %{
    "collect" => :collect,
    "followup" => :followup,
    "steer" => :steer,
    "steer_backlog" => :steer_backlog,
    "redirect" => :redirect,
    "interrupt" => :interrupt
  }

  @impl true
  def name, do: "agent"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, ctx) do
    with :ok <- reject_legacy_selector(params),
         :ok <- reject_renamed_fields(params),
         {:ok, validated} <- validate_params(params),
         {:ok, run_id} <- ChatSubmission.run_id(params),
         {:ok, request} <- build_request(validated, run_id),
         {:ok, result} <- submit(validated, request, ctx) do
      {:ok, Map.put(result, "summary", summary(validated, result))}
    end
  end

  defp summary(params, result) do
    %{
      "agentId" => params.agent_id,
      "sessionKey" => result["sessionKey"],
      "runId" => result["runId"],
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

  defp reject_renamed_fields(params) when is_map(params) do
    case Enum.filter(Map.keys(@renamed_fields), &Map.has_key?(params, &1)) do
      [] ->
        :ok

      fields ->
        renames = Enum.map_join(fields, ", ", &"#{&1} -> #{@renamed_fields[&1]}")
        {:error, Errors.invalid_params("Renamed agent parameters: #{renames}", %{fields: fields})}
    end
  end

  defp reject_renamed_fields(_), do: :ok

  defp validate_params(nil) do
    {:error, Errors.invalid_params("params is required")}
  end

  defp validate_params(params) when is_map(params) do
    case Map.get(params, "prompt") do
      nil ->
        {:error, Errors.invalid_params("prompt is required")}

      prompt when is_binary(prompt) and byte_size(prompt) > 0 ->
        with :ok <- validate_context_options(params),
             :ok <- validate_key(params, "sessionKey"),
             :ok <- validate_key(params, "agentId"),
             {:ok, queue_mode} <- parse_queue_mode(Map.get(params, "queueMode")),
             {:ok, tool_policy} <- parse_optional_tool_policy(Map.get(params, "tool_policy")),
             :ok <- validate_project_memory_capture(params) do
          {:ok,
           %{
             prompt: prompt,
             agent_id: Map.get(params, "agentId", "default"),
             session_key: Map.get(params, "sessionKey"),
             model: Map.get(params, "model"),
             queue_mode: queue_mode,
             cwd_given?: Map.has_key?(params, "cwd"),
             cwd: Map.get(params, "cwd"),
             tool_policy: tool_policy,
             raw_tool_policy: Map.get(params, "tool_policy"),
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

  # Session and agent keys name router-owned state: an empty, blank, oversized
  # or control-character key is refused before any run ID or admission row.
  defp validate_key(params, field) do
    case Map.fetch(params, field) do
      :error ->
        :ok

      {:ok, key} when is_binary(key) and byte_size(key) in 1..1024 ->
        if String.valid?(key) and String.trim(key) != "" and
             not String.match?(key, ~r/[[:cntrl:]]/u),
           do: :ok,
           else: invalid_key(field)

      {:ok, _key} ->
        invalid_key(field)
    end
  end

  defp invalid_key(field) do
    {:error,
     Errors.invalid_params(
       "#{field} must be a nonblank string of at most 1024 bytes without control characters"
     )}
  end

  defp parse_queue_mode(nil), do: {:ok, :collect}

  defp parse_queue_mode(mode) do
    case Map.fetch(@queue_modes, mode) do
      {:ok, queue_mode} ->
        {:ok, queue_mode}

      :error ->
        {:error,
         Errors.invalid_params(
           "queueMode must be one of collect, followup, steer, steer_backlog, redirect, interrupt"
         )}
    end
  end

  defp parse_optional_tool_policy(nil), do: {:ok, nil}

  defp parse_optional_tool_policy(policy) do
    case ToolPolicy.parse(policy) do
      {:ok, policy} -> {:ok, policy}
      {:error, _reason} -> {:error, Errors.invalid_params("tool_policy is invalid")}
    end
  end

  # An agent ID that names a managed profile runs as that profile's chat, the
  # same request `chat.send` builds for `profileId`.
  defp build_request(params, run_id) do
    case LemonCore.ProfileStore.get_for_execution(params.agent_id) do
      {:ok, profile} -> profile_request(profile, params, run_id)
      {:error, reason} when reason in [:not_found, :invalid_id] -> agent_request(params, run_id)
      {:error, _} -> {:error, {:unavailable, "Profile is unavailable", nil}}
    end
  end

  defp profile_request(_profile, %{cwd_given?: true}, _run_id) do
    {:error, {:invalid_request, "cwd cannot override a profile workspace", nil}}
  end

  defp profile_request(profile, params, run_id) do
    with {:ok, policy} <- profile_tool_policy(params.raw_tool_policy),
         {:ok, request} <-
           LemonCore.ProfileStore.chat_request(profile, params.prompt,
             session_key: params.session_key,
             run_id: run_id,
             queue_mode: params.queue_mode,
             model: params.model,
             tool_policy: policy,
             meta: meta(params)
           ) do
      {:ok, request}
    else
      {:error, {_code, _message} = error} -> {:error, error}
      {:error, _} -> {:error, {:invalid_request, "Profile agent request is invalid", nil}}
    end
  end

  defp profile_tool_policy(nil), do: {:ok, %{}}

  defp profile_tool_policy(policy) do
    case ToolPolicy.normalize(policy) do
      {:ok, policy} -> {:ok, policy}
      {:error, _} -> {:error, Errors.invalid_params("tool_policy is invalid")}
    end
  end

  defp agent_request(params, run_id) do
    session_key = params.session_key || "agent:#{params.agent_id}:main"

    cond do
      params.cwd_given? and not ChatSubmission.valid_cwd?(params.cwd) ->
        {:error, {:invalid_request, "cwd must be a nonempty absolute existing directory", nil}}

      params.cwd_given? and ChatSubmission.profile_session?(session_key) ->
        {:error, {:invalid_request, "cwd cannot override a canonical profile session", nil}}

      true ->
        {:ok,
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
           meta: meta(params)
         })}
    end
  end

  defp meta(params) do
    %{
      control_plane: true,
      project_memory_capture: params.project_memory_capture,
      session_mode: params.session_mode,
      persona: params.persona
    }
  end

  defp submit(%{idempotency_key: nil}, request, ctx) do
    case dispatch(request, ctx) do
      {:ok, _result} = ok -> ok
      {:error, _outcome, error} -> {:error, error}
    end
  end

  defp submit(%{idempotency_key: key}, request, ctx), do: submit_once(key, request, ctx)

  # The key is claimed atomically before the router is called, so concurrent
  # requests submit once. The claim carries the fixed run ID and never expires:
  # an unknown router outcome keeps it, and every later request with the key
  # gets that run ID back instead of a second submission until the router's
  # receipt proves the run was admitted or aborted before dispatch.
  defp submit_once(key, request, ctx) do
    pending = %{"run_id" => request.run_id, "session_key" => request.session_key}

    case LemonCore.Idempotency.begin(:agent, key, pending) do
      {:new, claim} ->
        case dispatch(request, ctx) do
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

  # Only a definite rejection may release an idempotency claim.
  defp dispatch(request, ctx) do
    router = Map.get(ctx, :router_mod, LemonRouter)

    case ChatSubmission.submit(request, &router.submit_with_receipt/1) do
      {:ok, result} ->
        {:ok, result}

      {:error, {_code, _message, %{"code" => "SUBMISSION_OUTCOME_UNKNOWN"}} = error} ->
        {:error, :outcome_unknown, error}

      {:error, error} ->
        {:error, :rejected, error}
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
      {:ok, %{state: state} = receipt} when state in [:accepted, :terminal] ->
        result = ChatSubmission.project(receipt)
        _ = LemonCore.Idempotency.complete(claim, result)
        {:ok, result}

      {:ok, %{state: state}} when state in [:aborted, :rejected] ->
        retry_safe = LemonCore.Idempotency.release(claim) == :ok

        {code, message} =
          case state do
            :aborted -> {"SUBMISSION_ABORTED", "The earlier request was aborted before it ran"}
            :rejected -> {"SUBMISSION_REJECTED", "The earlier request was rejected before it ran"}
          end

        {:error,
         Errors.error(:conflict, message, %{
           "code" => code,
           "runId" => run_id,
           "sessionKey" => session_key,
           "retrySafe" => retry_safe
         })}

      _unproven ->
        {:error,
         Errors.error(
           :unavailable,
           "A request with this idempotency_key is in progress or its outcome is unknown",
           %{
             "code" => "SUBMISSION_OUTCOME_UNKNOWN",
             "runId" => run_id,
             "sessionKey" => session_key,
             "retrySafe" => false
           }
         )}
    end
  end
end
