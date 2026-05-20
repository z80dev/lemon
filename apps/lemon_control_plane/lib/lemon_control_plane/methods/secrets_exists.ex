defmodule LemonControlPlane.Methods.SecretsExists do
  @moduledoc """
  Handler for `secrets.exists`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "secrets.exists"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    name = params["name"]

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, Errors.invalid_request("name is required")}

      true ->
        exists? =
          LemonCore.Secrets.exists?(name,
            prefer_env: params["preferEnv"] == true,
            env_fallback: params["envFallback"] != false
          )

        {:ok,
         %{
           "name" => String.trim(name),
           "exists" => exists?,
           "summary" => summary(String.trim(name), exists?, params)
         }}
    end
  end

  defp summary(name, exists?, params) do
    %{
      "name" => name,
      "exists" => exists?,
      "preferEnv" => params["preferEnv"] == true,
      "envFallback" => params["envFallback"] != false,
      "cleanup" => %{
        "includesSecretValues" => false,
        "includesRawKeyMaterial" => false,
        "includesCredentialValues" => false
      }
    }
  end
end
