defmodule LemonControlPlane.Methods.SecretsSet do
  @moduledoc """
  Handler for `secrets.set`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "secrets.set"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    name = params["name"]
    value = params["value"]

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, Errors.invalid_request("name is required")}

      not is_binary(value) ->
        {:error, Errors.invalid_request("value must be a string")}

      true ->
        opts =
          []
          |> maybe_put(:provider, params["provider"])
          |> maybe_put(:expires_at, params["expiresAt"])

        case LemonCore.Secrets.set(name, value, opts) do
          {:ok, metadata} ->
            {:ok,
             %{
               "ok" => true,
               "secret" => format_metadata(metadata)
             }}

          {:error, reason} ->
            {:error, Errors.invalid_request(format_error(reason))}
        end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_metadata(metadata) do
    %{
      "owner" => metadata.owner,
      "name" => metadata.name,
      "provider" => metadata.provider,
      "expiresAt" => metadata.expires_at,
      "usageCount" => metadata.usage_count,
      "lastUsedAt" => metadata.last_used_at,
      "createdAt" => metadata.created_at,
      "updatedAt" => metadata.updated_at,
      "version" => metadata.version
    }
  end

  defp format_error(:missing_master_key), do: "master key is not configured"
  defp format_error(:invalid_master_key), do: "configured master key is invalid"
  defp format_error(:invalid_secret_name), do: "secret name is invalid"
  defp format_error(:invalid_secret_value), do: "secret value is invalid"
  defp format_error(_), do: "failed to store secret"
end
