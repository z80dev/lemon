defmodule LemonControlPlane.Methods.ProviderManagementSupport do
  @moduledoc false
  alias LemonControlPlane.Protocol.Errors

  def handle(operation, params, ctx, node?) do
    with :ok <- LemonCore.ProviderManagement.validate(operation, params, node?),
         {:ok, result} <- dispatch(operation, params, ctx, node?),
         {:ok, result} <- project(operation, result, params) do
      {:ok, result}
    else
      {:error, {:unavailable, _}} ->
        unavailable(operation)

      {:error, {_, _, _} = error} ->
        {:error, error}

      {:error, {_, _} = error} ->
        {:error, error}

      {:error, reason}
      when reason in [
             :invalid_request,
             :invalid_provider,
             :unsupported_method,
             :invalid_api_key,
             :invalid_model,
             :invalid_target
           ] ->
        {:error, Errors.invalid_request("Invalid provider management request")}

      {:error, :target_mismatch} ->
        {:error, Errors.error(:conflict, "Provider target does not match this machine")}

      {:error, :provider_binding_rejected} ->
        {:error,
         Errors.error(:forbidden, "Provider login binding rejected by destination", %{
           "reason" => "provider_binding_rejected",
           "retrySafe" => false,
           "mutationMayHaveApplied" => false
         })}

      {:error, :forbidden} ->
        {:error, Errors.forbidden("Provider login belongs to another owner or session")}

      {:error, _} ->
        unavailable(operation)
    end
  rescue
    _ -> unavailable(operation)
  catch
    _, _ -> unavailable(operation)
  end

  defp project("device.challenge", result, params),
    do: LemonCore.ProviderManagement.device_challenge_result(result, params)

  defp project("device." <> _, result, params),
    do: LemonCore.ProviderManagement.device_result(result, params)

  defp project(_, result, _), do: {:ok, result}

  defp unavailable("list"),
    do: {:error, Errors.error(:unavailable, "Provider management unavailable")}

  defp unavailable(_),
    do:
      {:error,
       Errors.error(
         :unavailable,
         "Provider management unavailable; reconcile before another mutation",
         %{"retrySafe" => false, "mutationMayHaveApplied" => true}
       )}

  defp dispatch("device.complete", %{"commit" => false} = params, ctx, true) do
    LemonControlPlane.NodeIO.invoke(
      params["nodeId"],
      "node.providers.management.device.complete",
      Map.delete(params, "nodeId"),
      ctx
    )
  end

  defp dispatch("device.complete", %{"commit" => true} = params, ctx, true) do
    node_id = params["nodeId"]

    with {:ok, node} <- LemonCore.NodeRegistry.resolve_id(node_id),
         {:ok, authority} <-
           LemonControlPlane.Auth.TokenStore.provider_completion_authority(
             node_id,
             Map.get(ctx, :provider_completion_now_ms, System.system_time(:millisecond))
           ),
         true <- node.generation == authority.generation do
      LemonControlPlane.NodeIO.invoke(
        node_id,
        "node.providers.management.device.complete",
        Map.delete(params, "nodeId"),
        ctx,
        expected_pid: node.pid,
        expected_generation: node.generation
      )
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp dispatch(operation, params, ctx, true) do
    LemonControlPlane.NodeIO.invoke(
      params["nodeId"],
      "node.providers.management." <> operation,
      Map.delete(params, "nodeId"),
      ctx
    )
  end

  defp dispatch(operation, params, ctx, false),
    do: LemonCore.ProviderManagement.execute(operation, params, authority: ctx[:conn_pid])
end

for {module, operation, node?} <- [
      {LemonControlPlane.Methods.ProvidersManagementList, "list", false},
      {LemonControlPlane.Methods.ProvidersManagementApiKeySet, "api_key.set", false},
      {LemonControlPlane.Methods.ProvidersManagementDisconnect, "disconnect", false},
      {LemonControlPlane.Methods.ProvidersManagementDefaultSet, "default.set", false},
      {LemonControlPlane.Methods.ProvidersManagementDeviceStart, "device.start", false},
      {LemonControlPlane.Methods.ProvidersManagementDevicePoll, "device.poll", false},
      {LemonControlPlane.Methods.ProvidersManagementDeviceChallenge, "device.challenge", false},
      {LemonControlPlane.Methods.ProvidersManagementDeviceCancel, "device.cancel", false},
      {LemonControlPlane.Methods.ProvidersManagementDeviceComplete, "device.complete", false},
      {LemonControlPlane.Methods.NodeProvidersManagementList, "list", true},
      {LemonControlPlane.Methods.NodeProvidersManagementApiKeySet, "api_key.set", true},
      {LemonControlPlane.Methods.NodeProvidersManagementDisconnect, "disconnect", true},
      {LemonControlPlane.Methods.NodeProvidersManagementDefaultSet, "default.set", true},
      {LemonControlPlane.Methods.NodeProvidersManagementDeviceStart, "device.start", true},
      {LemonControlPlane.Methods.NodeProvidersManagementDevicePoll, "device.poll", true},
      {LemonControlPlane.Methods.NodeProvidersManagementDeviceChallenge, "device.challenge",
       true},
      {LemonControlPlane.Methods.NodeProvidersManagementDeviceCancel, "device.cancel", true},
      {LemonControlPlane.Methods.NodeProvidersManagementDeviceComplete, "device.complete", true}
    ] do
  defmodule module do
    @moduledoc "Owner-authorized write-only provider management."
    @behaviour LemonControlPlane.Method
    @operation operation
    @node node?
    @impl true
    def name, do: if(@node, do: "node.", else: "") <> "providers.management." <> @operation
    @impl true
    def scopes, do: [:admin]
    @impl true
    def dispatch_mode, do: :async
    @impl true
    def handle(params, ctx),
      do:
        LemonControlPlane.Methods.ProviderManagementSupport.handle(@operation, params, ctx, @node)
  end
end
