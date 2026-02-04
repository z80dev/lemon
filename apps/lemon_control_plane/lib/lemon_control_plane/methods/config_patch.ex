defmodule LemonControlPlane.Methods.ConfigPatch do
  @moduledoc """
  Handler for the config.patch control plane method.

  Applies a partial configuration update.
  """

  @behaviour LemonControlPlane.Method

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
        LemonCore.Store.put(:system_config, key, value)
      end)

      {:ok, %{
        "success" => true,
        "applied" => Map.keys(patch)
      }}
    end
  end
end
