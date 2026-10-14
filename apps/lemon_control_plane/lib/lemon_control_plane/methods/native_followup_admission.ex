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
        {:ok, _secret_name} -> {:ok, %{"profileId" => params["profileId"], "configured" => true}}
        {:error, :profile_not_found} -> {:error, Errors.error(:not_found, "Profile not found")}
        {:error, :invalid_request} -> {:error, Errors.invalid_request("Invalid follow-up admission configuration")}
        {:error, _} -> {:error, Errors.error(:unavailable, "Follow-up admission configuration unavailable")}
      end
    else
      {:error, Errors.invalid_request("Invalid follow-up admission configuration")}
    end
  end
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
        {:ok, projection} -> {:ok, projection}
        {:error, :not_found} -> {:error, Errors.error(:not_found, "Pending follow-up lineage not found")}
        {:error, _} -> {:error, Errors.error(:unavailable, "Follow-up lineage unavailable")}
      end
    else
      _ -> {:error, Errors.invalid_request("Invalid follow-up run identity")}
    end
  end
end
