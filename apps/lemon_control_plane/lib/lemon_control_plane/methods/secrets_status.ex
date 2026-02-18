defmodule LemonControlPlane.Methods.SecretsStatus do
  @moduledoc """
  Handler for `secrets.status`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "secrets.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    status = LemonCore.Secrets.status()

    {:ok,
     %{
       "configured" => status.configured,
       "source" => format_source(status.source),
       "keychainAvailable" => status.keychain_available,
       "envFallback" => status.env_fallback,
       "owner" => status.owner,
       "count" => status.count
     }}
  end

  defp format_source(nil), do: nil
  defp format_source(source), do: to_string(source)
end
