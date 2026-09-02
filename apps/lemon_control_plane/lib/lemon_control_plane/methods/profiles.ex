defmodule LemonControlPlane.Methods.ProfilesSupport do
  @moduledoc false

  require Logger

  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.{NodeRegistry, ProfileStore}

  def profile_attrs(params) do
    %{
      "id" => params["id"],
      "name" => params["name"],
      "description" => params["description"],
      "avatar" => params["avatar"],
      "model" => params["model"],
      "systemPrompt" => params["systemPrompt"],
      "node" => params["node"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def refresh(id \\ nil) do
    if Process.whereis(LemonRouter.AgentProfiles) == nil do
      :ok
    else
      LemonRouter.AgentProfiles.reload()
      _ = LemonRouter.AgentProfiles.list()

      if is_binary(id) and not LemonRouter.AgentProfiles.exists?(id) do
        {:error, :runtime_profile_reload_failed}
      else
        :ok
      end
    end
  catch
    :exit, reason -> {:error, {:runtime_profile_unavailable, reason}}
  end

  def roster do
    ProfileStore.list()
    |> Enum.map(fn profile ->
      node = profile["node"] || "local"

      availability =
        cond do
          node == "local" -> "local"
          node_online?(node) -> "online"
          true -> "offline"
        end

      profile
      |> Map.take(~w(id name description avatar model node canonicalSessionKey))
      |> Map.merge(%{
        "availability" => availability,
        "workspace" => profile["paths"]["workspace"]
      })
    end)
  end

  def result(profile), do: %{"profile" => profile, "summary" => profile_summary(profile)}

  def profile_summary(profile) do
    %{
      "profileId" => profile["id"],
      "sessionKey" => profile["canonicalSessionKey"],
      "node" => profile["node"],
      "cleanup" => %{
        "includesPromptText" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  def error(:not_found), do: {:error, Errors.error(:not_found, "Profile not found")}
  def error(:already_exists), do: {:error, Errors.error(:conflict, "Profile already exists")}

  def error(:confirmation_required),
    do: {:error, Errors.invalid_request("Profile operation failed: confirmation_required")}

  def error(reason) when reason in [:invalid_id, :invalid_profile, :reserved_profile] do
    {:error, Errors.invalid_request("Profile operation is invalid")}
  end

  def error({:invalid_field, _field}),
    do: {:error, Errors.invalid_request("Profile field is invalid")}

  def error({:field_too_large, _field, _max}),
    do: {:error, Errors.invalid_request("Profile field is too large")}

  def error(reason) when reason in [:invalid_destination, :destination_is_directory],
    do: {:error, Errors.invalid_request("Profile export destination is invalid")}

  def error(:destination_exists),
    do: {:error, Errors.error(:conflict, "Profile export destination already exists")}

  def error(reason) do
    Logger.warning("Profile operation failed class=#{failure_class(reason)}")
    {:error, Errors.internal_error("Profile operation failed")}
  end

  def submission_outcome_unknown(request, profile) do
    {:error,
     Errors.error(:unavailable, "Profile chat submission outcome is unknown", %{
       "code" => "SUBMISSION_OUTCOME_UNKNOWN",
       "runId" => request.run_id,
       "profileId" => profile["id"],
       "sessionKey" => request.session_key,
       "retrySafe" => false
     })}
  end

  def queue_mode(nil), do: :collect
  def queue_mode("collect"), do: :collect
  def queue_mode("followup"), do: :followup
  def queue_mode("steer"), do: :steer
  def queue_mode("redirect"), do: :redirect
  def queue_mode("interrupt"), do: :interrupt
  def queue_mode(_), do: :collect

  defp node_online?(node) do
    Process.whereis(NodeRegistry) != nil and NodeRegistry.online?(node)
  catch
    :exit, _ -> false
  end

  defp failure_class(%{__exception__: true, __struct__: module}) when is_atom(module),
    do: "exception:" <> inspect(module)

  defp failure_class(reason) when is_atom(reason), do: "atom"
  defp failure_class(reason) when is_tuple(reason), do: "tuple"
  defp failure_class(reason) when is_map(reason), do: "map"
  defp failure_class(reason) when is_list(reason), do: "list"
  defp failure_class(_reason), do: "other"
end

defmodule LemonControlPlane.Methods.ProfilesList do
  @moduledoc false
  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "profiles.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    profiles = LemonCore.ProfileStore.list()
    {:ok, %{"profiles" => profiles, "count" => length(profiles)}}
  end
end

defmodule LemonControlPlane.Methods.ProfilesGet do
  @moduledoc false
  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "profiles.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    case LemonCore.ProfileStore.get(params["id"]) do
      {:ok, profile} -> {:ok, LemonControlPlane.Methods.ProfilesSupport.result(profile)}
      {:error, reason} -> LemonControlPlane.Methods.ProfilesSupport.error(reason)
    end
  end
end

defmodule LemonControlPlane.Methods.ProfilesCreate do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Methods.ProfilesSupport

  @impl true
  def name, do: "profiles.create"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, profile} <- LemonCore.ProfileStore.create(ProfilesSupport.profile_attrs(params)),
         :ok <- ProfilesSupport.refresh(profile["id"]) do
      {:ok, ProfilesSupport.result(profile)}
    else
      {:error, reason} -> ProfilesSupport.error(reason)
    end
  end
end

defmodule LemonControlPlane.Methods.ProfilesClone do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Methods.ProfilesSupport

  @impl true
  def name, do: "profiles.clone"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, profile} <-
           LemonCore.ProfileStore.clone(
             params["sourceId"],
             ProfilesSupport.profile_attrs(params)
           ),
         :ok <- ProfilesSupport.refresh(profile["id"]) do
      {:ok, ProfilesSupport.result(profile)}
    else
      {:error, reason} -> ProfilesSupport.error(reason)
    end
  end
end

defmodule LemonControlPlane.Methods.ProfilesRename do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Methods.ProfilesSupport

  @impl true
  def name, do: "profiles.rename"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, profile} <- LemonCore.ProfileStore.rename(params["id"], params["name"]),
         :ok <- ProfilesSupport.refresh(profile["id"]) do
      {:ok, ProfilesSupport.result(profile)}
    else
      {:error, reason} -> ProfilesSupport.error(reason)
    end
  end
end

defmodule LemonControlPlane.Methods.ProfilesExport do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Methods.ProfilesSupport

  @impl true
  def name, do: "profiles.export"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    case LemonCore.ProfileStore.export(params["id"], params["path"],
           force: params["force"] || false
         ) do
      {:ok, result} ->
        {:ok,
         %{
           "export" => result,
           "summary" => %{
             "profileId" => result["profileId"],
             "fileCount" => result["fileCount"],
             "omittedCount" => result["omittedCount"],
             "redactionCount" => result["redactionCount"],
             "cleanup" => %{
               "includesSessions" => false,
               "includesMemory" => false,
               "includesCredentials" => false,
               "includesSecretValues" => false
             }
           }
         }}

      {:error, reason} ->
        ProfilesSupport.error(reason)
    end
  end
end

defmodule LemonControlPlane.Methods.ProfilesDelete do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Methods.ProfilesSupport

  @impl true
  def name, do: "profiles.delete"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, result} <-
           LemonCore.ProfileStore.delete(params["id"], confirm: params["confirm"]),
         :ok <- ProfilesSupport.refresh() do
      {:ok,
       %{
         "deleted" => result,
         "summary" => %{
           "profileId" => result["id"],
           "sessionKey" => result["canonicalSessionKey"],
           "homeMoved" => result["homeMoved"],
           "cleanup" => %{
             "includesCredentials" => false,
             "includesSecretValues" => false
           }
         }
       }}
    else
      {:error, reason} -> ProfilesSupport.error(reason)
    end
  end
end

defmodule LemonControlPlane.Methods.ProfilesRoster do
  @moduledoc false
  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "profiles.roster"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    profiles = LemonControlPlane.Methods.ProfilesSupport.roster()

    {:ok,
     %{
       "profiles" => profiles,
       "count" => length(profiles),
       "availabilityCounts" => Enum.frequencies_by(profiles, & &1["availability"])
     }}
  end
end

defmodule LemonControlPlane.Methods.ProfileChat do
  @moduledoc false
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Methods.ProfilesSupport

  @impl true
  def name, do: "profile.chat"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    id = params["id"]

    with {:ok, profile} <- LemonCore.ProfileStore.get(id),
         :ok <- ProfilesSupport.refresh(id),
         {:ok, base_request} <-
           LemonCore.ProfileStore.chat_request(profile, params["prompt"],
             model: params["model"],
             queue_mode: ProfilesSupport.queue_mode(params["queueMode"]),
             meta: %{control_plane: true}
           ) do
      request = %{base_request | run_id: LemonCore.Id.run_id()}

      case LemonCore.RouterBridge.submit_run(request) do
        {:ok, run_id} ->
          {:ok,
           %{
             "runId" => run_id,
             "profileId" => id,
             "sessionKey" => request.session_key,
             "node" => profile["node"],
             "summary" => %{
               "runId" => run_id,
               "profileId" => id,
               "sessionKey" => request.session_key,
               "node" => profile["node"],
               "queueMode" => to_string(request.queue_mode),
               "promptBytes" => byte_size(params["prompt"]),
               "cleanup" => %{
                 "includesPromptText" => false,
                 "includesMessageBodies" => false,
                 "includesCredentials" => false,
                 "includesSecretValues" => false
               }
             }
           }}

        {:error, :outcome_unknown} ->
          ProfilesSupport.submission_outcome_unknown(request, profile)

        {:error, reason} ->
          ProfilesSupport.error(reason)
      end
    else
      {:error, reason} -> ProfilesSupport.error(reason)
    end
  end
end
