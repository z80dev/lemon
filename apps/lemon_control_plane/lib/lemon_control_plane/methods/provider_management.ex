defmodule LemonControlPlane.Methods.ProviderManagementSupport do
  @moduledoc false
  alias LemonControlPlane.Protocol.Errors

  def handle(operation, params, ctx, node?) do
    with :ok <- LemonCore.ProviderManagement.validate(operation, params, node?),
         {:ok, result} <- dispatch(operation, params, ctx, node?) do
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

      {:error, _} ->
        unavailable(operation)
    end
  rescue
    _ -> unavailable(operation)
  catch
    _, _ -> unavailable(operation)
  end

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

  defp dispatch(operation, params, ctx, true) do
    LemonControlPlane.NodeIO.invoke(
      params["nodeId"],
      "node.providers.management." <> operation,
      Map.delete(params, "nodeId"),
      ctx
    )
  end

  defp dispatch(operation, params, _, false),
    do: LemonCore.ProviderManagement.execute(operation, params)
end

for {module, operation, node?} <- [
      {LemonControlPlane.Methods.ProvidersManagementList, "list", false},
      {LemonControlPlane.Methods.ProvidersManagementApiKeySet, "api_key.set", false},
      {LemonControlPlane.Methods.ProvidersManagementDisconnect, "disconnect", false},
      {LemonControlPlane.Methods.ProvidersManagementDefaultSet, "default.set", false},
      {LemonControlPlane.Methods.NodeProvidersManagementList, "list", true},
      {LemonControlPlane.Methods.NodeProvidersManagementApiKeySet, "api_key.set", true},
      {LemonControlPlane.Methods.NodeProvidersManagementDisconnect, "disconnect", true},
      {LemonControlPlane.Methods.NodeProvidersManagementDefaultSet, "default.set", true}
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
