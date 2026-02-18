defmodule LemonControlPlane.Methods.SecretsList do
  @moduledoc """
  Handler for `secrets.list`.

  Returns secret metadata only, never plaintext values.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "secrets.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    owner = params["owner"]

    opts =
      if is_binary(owner) and String.trim(owner) != "" do
        [owner: owner]
      else
        []
      end

    {:ok, entries} = LemonCore.Secrets.list(opts)
    owner = Keyword.get(opts, :owner, LemonCore.Secrets.default_owner())

    {:ok,
     %{
       "owner" => owner,
       "secrets" => Enum.map(entries, &format_metadata/1)
     }}
  end

  defp format_metadata(entry) do
    %{
      "owner" => entry.owner,
      "name" => entry.name,
      "provider" => entry.provider,
      "expiresAt" => entry.expires_at,
      "usageCount" => entry.usage_count,
      "lastUsedAt" => entry.last_used_at,
      "createdAt" => entry.created_at,
      "updatedAt" => entry.updated_at,
      "version" => entry.version
    }
  end
end
