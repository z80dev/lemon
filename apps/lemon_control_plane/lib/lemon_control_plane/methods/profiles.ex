defmodule LemonControlPlane.Methods.ProfilesSupport do
  @moduledoc false

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

  def error(reason) do
    {:error, Errors.invalid_request("Profile operation failed: #{inspect(reason)}")}
  end

  def queue_mode(nil), do: :collect
  def queue_mode("collect"), do: :collect
  def queue_mode("followup"), do: :followup
  def queue_mode("steer"), do: :steer
  def queue_mode("interrupt"), do: :interrupt
  def queue_mode(_), do: :collect

  defp node_online?(node) do
    Process.whereis(NodeRegistry) != nil and NodeRegistry.online?(node)
  catch
    :exit, _ -> false
  end
end

defmodule LemonControlPlane.Methods.ProfilesList do
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
         {:ok, request} <-
           LemonCore.ProfileStore.chat_request(profile, params["prompt"],
             model: params["model"],
             queue_mode: ProfilesSupport.queue_mode(params["queueMode"]),
             meta: %{control_plane: true}
           ),
         {:ok, run_id} <- LemonCore.RouterBridge.submit_run(request) do
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
    else
      {:error, reason} -> ProfilesSupport.error(reason)
    end
  end
end
