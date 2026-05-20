defmodule LemonControlPlane.Methods.ConfigPatch do
  @moduledoc """
  Handler for the config.patch control plane method.

  Applies a partial configuration update.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.ConfigStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "config.patch"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    patch = params["patch"]

    if not is_map(patch) or map_size(patch) == 0 do
      {:error, Errors.invalid_request("patch must be a non-empty map")}
    else
      # Apply each key-value pair
      Enum.each(patch, fn {key, value} ->
        ConfigStore.put(key, value)
      end)

      {:ok,
       %{
         "success" => true,
         "applied" => Map.keys(patch),
         "summary" => summary(patch)
       }}
    end
  end

  defp summary(patch) do
    keys = Map.keys(patch)

    %{
      "appliedCount" => length(keys),
      "appliedKeys" => keys,
      "sensitiveKeyCount" => Enum.count(keys, &sensitive_key?/1),
      "cleanup" => %{
        "includesValues" => false,
        "includesCredentialValues" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp sensitive_key?(key) when is_binary(key) do
    key
    |> String.downcase()
    |> then(fn lowered ->
      String.contains?(lowered, "secret") or
        String.contains?(lowered, "token") or
        String.contains?(lowered, "key") or
        String.contains?(lowered, "password")
    end)
  end

  defp sensitive_key?(_), do: false
end
