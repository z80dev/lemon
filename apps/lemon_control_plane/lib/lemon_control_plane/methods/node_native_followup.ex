defmodule LemonControlPlane.Methods.NodeNativeFollowup do
  @moduledoc "Authenticated native continuation submission; authority comes from the owning source receipt."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.NodeNativeLineageFloor
  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.RunRequest

  @impl true
  def name, do: "node.native.followup"

  @impl true
  def scopes, do: [:invoke]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, ctx) do
    with {:ok, source, transport} <- NodeNativeLineageFloor.source(params, ctx),
         request when is_map(request) <- params["request"],
         {:ok, _} <-
           LemonCore.JSONPayload.validate(request, LemonCore.ToolPolicy.execution_json_opts()),
         :ok <- RunRequest.validate_invocation_context_key(request["runId"]),
         true <- is_binary(request["runId"]) and request["runId"] != "",
         prompt when is_binary(prompt) <- request["prompt"],
         true <- String.trim(prompt) != "",
         true <- is_nil(request["meta"]) or is_map(request["meta"]),
         {:ok, policy} <- LemonCore.ToolPolicy.normalize(request["toolPolicy"] || %{}) do
      request =
        RunRequest.new(%{
          run_id: request["runId"],
          origin: :node,
          agent_id: request["agentId"],
          session_key: request["sessionKey"],
          prompt: prompt,
          images: request["images"] || [],
          model: request["model"],
          model_explicit: request["modelExplicit"],
          cwd: request["cwd"],
          tool_policy: policy,
          queue_mode: :collect,
          meta: request["meta"] || %{}
        })

      case LemonRouter.RunOrchestrator.submit_native_followup_from_node(
             source,
             request,
             transport
           ) do
        {:ok, run_id} when is_binary(run_id) and run_id != "" ->
          {:ok, %{"runId" => run_id}}

        {:error, :outcome_unknown} ->
          {:error,
           Errors.error(:unavailable, "Native continuation outcome is unknown", %{
             "code" => "SUBMISSION_OUTCOME_UNKNOWN",
             "runId" => request.run_id,
             "retrySafe" => false
           })}

        {:error, _} ->
          {:error, Errors.forbidden("Native continuation admission is unavailable")}
      end
    else
      {:error, {_kind, _message} = error} -> {:error, error}
      _ -> {:error, Errors.invalid_request("Invalid native continuation request")}
    end
  end
end
