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

    cleanup = %{
      "includesSecretValues" => false,
      "includesRawKeyMaterial" => false,
      "includesRawKeychainErrors" => false
    }

    {:ok,
     %{
       "configured" => status.configured,
       "source" => format_source(status.source),
       "keychainAvailable" => status.keychain_available,
       "envFallback" => status.env_fallback,
       "fileFallback" => Map.get(status, :file_fallback, false),
       "keychainErrorKind" => error_kind(status.keychain_error),
       "healthy" => status.configured,
       "owner" => status.owner,
       "count" => status.count,
       "cleanup" => cleanup,
       "summary" => summary(status, cleanup)
     }}
  end

  defp summary(status, cleanup) do
    %{
      "action" => "secrets.status",
      "configured" => status.configured,
      "healthy" => status.configured,
      "source" => format_source(status.source),
      "keychainAvailable" => status.keychain_available,
      "envFallback" => status.env_fallback,
      "fileFallback" => Map.get(status, :file_fallback, false),
      "secretCount" => status.count,
      "cleanup" => cleanup
    }
  end

  defp format_source(nil), do: nil
  defp format_source(source), do: to_string(source)

  defp error_kind(nil), do: nil
  defp error_kind({kind, _code, _message}) when is_atom(kind), do: Atom.to_string(kind)
  defp error_kind({kind, _reason}) when is_atom(kind), do: Atom.to_string(kind)
  defp error_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp error_kind(_), do: "unknown"
end
