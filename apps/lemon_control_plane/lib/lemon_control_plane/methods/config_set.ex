defmodule LemonControlPlane.Methods.ConfigSet do
  @moduledoc """
  Handler for the config.set control plane method.

  Sets a configuration value.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "config.set"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    key = params["key"]
    value = params["value"]

    cond do
      is_nil(key) or key == "" ->
        {:error, Errors.invalid_request("key is required")}

      is_nil(value) ->
        {:error, Errors.invalid_request("value is required")}

      true ->
        LemonCore.Store.put(:system_config, key, value)
        {:ok, %{"key" => key, "value" => value, "success" => true}}
    end
  end
end
