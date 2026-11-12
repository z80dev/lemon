defmodule LemonControlPlane.Methods.ProfileFollowupAdmissionSet do
  @moduledoc false
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors
  alias LemonRouter.NativeFollowupAdmission

  @impl true
  def name, do: "profile.followup.admission.set"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    if is_map(params) and map_size(params) == 3 and
         Enum.all?(~w(profileId url token), &Map.has_key?(params, &1)) do
      case NativeFollowupAdmission.configure(params["profileId"], params["url"], params["token"]) do
        {:ok, _secret_name} ->
          {:ok, %{"profileId" => params["profileId"], "configured" => true}}

        {:error, :profile_not_found} ->
          {:error, Errors.error(:not_found, "Profile not found")}

        {:error, reason}
        when reason == :invalid_request or reason == :callback_requires_https or
               reason == :invalid_callback_url or
               (is_tuple(reason) and elem(reason, 0) == :callback_origin_not_allowed) ->
          LemonControlPlane.Methods.AdmissionErrors.error(reason)

        {:error, _} ->
          {:error, Errors.error(:unavailable, "Follow-up admission configuration unavailable")}
      end
    else
      {:error, Errors.invalid_request("Invalid follow-up admission configuration")}
    end
  end
end

defmodule LemonControlPlane.Methods.ProfileFollowupAdmissionGet do
  @moduledoc false
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors
  alias LemonRouter.NativeFollowupAdmission

  @impl true
  def name, do: "profile.followup.admission.get"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(%{"profileId" => profile_id} = params, _ctx) when map_size(params) == 1 do
    case NativeFollowupAdmission.receipt(profile_id) do
      {:ok, receipt} ->
        {:ok, receipt}

      {:error, :profile_not_found} ->
        {:error, Errors.error(:not_found, "Profile not found")}

      {:error, :invalid_request} ->
        {:error, Errors.invalid_request("Invalid follow-up admission profile")}

      {:error, _} ->
        {:error, Errors.error(:unavailable, "Follow-up admission receipt unavailable")}
    end
  end

  def handle(_params, _ctx),
    do: {:error, Errors.invalid_request("Invalid follow-up admission profile")}
end

defmodule LemonControlPlane.Methods.AdmissionErrors do
  @moduledoc false

  alias LemonControlPlane.Protocol.Errors

  def error({:callback_origin_not_allowed, origin}) do
    {:error,
     Errors.error(:callback_origin_not_allowed, "Callback origin is not allowed", %{
       "origin" => origin
     })}
  end

  def error(:callback_requires_https),
    do: {:error, Errors.error(:callback_requires_https, "Callback requires HTTPS")}

  def error(:invalid_callback_url),
    do: {:error, Errors.error(:invalid_callback_url, "Invalid callback URL")}

  def error(:invalid_request),
    do: {:error, Errors.invalid_request("Invalid follow-up admission configuration")}

  def error(reason) when is_binary(reason), do: {:error, {:invalid_request, reason, nil}}
end

defmodule LemonControlPlane.Methods.RunsFollowupLineageGet do
  @moduledoc false
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "runs.followup.lineage.get"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with %{"runId" => run_id} when map_size(params) == 1 <- params,
         :ok <- LemonCore.RunRequest.validate_invocation_context_key(run_id) do
      case LemonRouter.NativeLineage.get_pending_lineage(run_id) do
        {:ok, projection} ->
          {:ok, projection}

        {:error, :not_found} ->
          {:error, Errors.error(:not_found, "Pending follow-up lineage not found")}

        {:error, _} ->
          {:error, Errors.error(:unavailable, "Follow-up lineage unavailable")}
      end
    else
      _ -> {:error, Errors.invalid_request("Invalid follow-up run identity")}
    end
  end
end
