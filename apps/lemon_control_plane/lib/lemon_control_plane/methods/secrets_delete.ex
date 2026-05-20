defmodule LemonControlPlane.Methods.SecretsDelete do
  @moduledoc """
  Handler for `secrets.delete`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "secrets.delete"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    name = params["name"]

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, Errors.invalid_request("name is required")}

      true ->
        case LemonCore.Secrets.delete(name) do
          :ok ->
            trimmed = String.trim(name)

            {:ok,
             %{
               "ok" => true,
               "name" => trimmed,
               "summary" => summary(trimmed)
             }}

          {:error, :invalid_secret_name} ->
            {:error, Errors.invalid_request("name is invalid")}

          _ ->
            {:error, Errors.internal_error("failed to delete secret")}
        end
    end
  end

  defp summary(name) do
    %{
      "name" => name,
      "deleted" => true,
      "cleanup" => %{
        "includesSecretValues" => false,
        "includesRawKeyMaterial" => false,
        "includesCredentialValues" => false
      }
    }
  end
end
