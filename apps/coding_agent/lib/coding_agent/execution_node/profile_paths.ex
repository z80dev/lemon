defmodule CodingAgent.ExecutionNode.ProfilePaths do
  @moduledoc """
  Read-only destination-owned path lookup for selected profile skill provisioning.

  Paths come from the execution host's canonical ProfileStore, never a caller's
  workspace, controller state root or default project cwd. Lookup does not create
  a profile, provision files or change placement.
  """

  @spec get(term()) :: {:ok, map()} | {:error, :invalid_profile_request}
  def get(%{"profileId" => id} = args) do
    with true <- map_size(args) == 1,
         {:ok, paths} <- LemonCore.ProfileStore.paths(id) do
      {:ok,
       %{
         "profileId" => id,
         "workspacePath" => paths["workspace"],
         "skillsPath" => paths["skills"]
       }}
    else
      _ -> {:error, :invalid_profile_request}
    end
  end

  def get(_), do: {:error, :invalid_profile_request}
end
