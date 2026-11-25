defmodule LemonControlPlane.Methods.SecretsSupport do
  @moduledoc false

  # Write-only `LemonCore.Secrets` mutations for one-shot CLI clients. While a
  # runtime owns the store, `lemon secrets set|delete|import-env` and gateway
  # setup send their write here instead of becoming a second store writer.
  # Responses carry metadata and a bounded reason, never a value.

  alias LemonControlPlane.Protocol.Errors

  @max_name_bytes 256
  @max_value_bytes 1_048_576
  @max_provider_bytes 128

  @reasons ~w(missing_master_key weak_master_key master_key_mismatch key_rotation_incomplete
              invalid_secret_name invalid_secret_value secrets_locked stale_revision)a

  def set(params) when is_map(params) do
    with {:ok, name} <- string(params, "name", @max_name_bytes),
         {:ok, value} <- string(params, "value", @max_value_bytes),
         {:ok, opts} <- set_opts(params) do
      case LemonCore.Secrets.set(name, value, opts) do
        {:ok, metadata} ->
          {:ok,
           %{
             "name" => metadata.name,
             "owner" => metadata.owner,
             "provider" => metadata.provider,
             "expiresAt" => metadata.expires_at
           }}

        {:error, reason} ->
          refused("Could not store the secret", reason)
      end
    end
  end

  def set(_params), do: {:error, Errors.invalid_request("params must be an object")}

  def delete(params) when is_map(params) do
    with {:ok, name} <- string(params, "name", @max_name_bytes) do
      case LemonCore.Secrets.delete(name) do
        :ok -> {:ok, %{"name" => String.trim(name), "deleted" => true}}
        {:error, reason} -> refused("Could not delete the secret", reason)
      end
    end
  end

  def delete(_params), do: {:error, Errors.invalid_request("params must be an object")}

  defp set_opts(params) do
    with {:ok, provider} <- optional_string(params, "provider", @max_provider_bytes),
         {:ok, expires_at} <- optional_expiry(params) do
      {:ok,
       Enum.reject([provider: provider, expires_at: expires_at], fn {_key, v} -> is_nil(v) end)}
    end
  end

  defp string(params, key, max_bytes) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" and byte_size(value) <= max_bytes ->
        {:ok, value}

      _ ->
        {:error, Errors.invalid_request("#{key} must be a non-empty string of bounded size")}
    end
  end

  defp optional_string(params, key, max_bytes) do
    if Map.has_key?(params, key), do: string(params, key, max_bytes), else: {:ok, nil}
  end

  defp optional_expiry(params) do
    case Map.get(params, "expiresAt") do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, Errors.invalid_request("expiresAt must be a positive integer")}
    end
  end

  # Secrets returns an error only when it wrote nothing.
  defp refused(message, reason) do
    reason = reason(reason)

    code =
      if reason in ["invalid_secret_name", "invalid_secret_value"],
        do: :invalid_request,
        else: :unavailable

    {:error,
     Errors.error(code, message, %{
       "reason" => reason,
       "retrySafe" => true,
       "mutationMayHaveApplied" => false
     })}
  end

  defp reason({:keychain_failed, _}), do: "keychain_failed"
  defp reason({:secrets_lock_held, _host}), do: "secrets_locked"
  defp reason(reason) when reason in @reasons, do: Atom.to_string(reason)
  defp reason(_reason), do: "secret_store_failed"
end

defmodule LemonControlPlane.Methods.SecretsSet do
  @moduledoc "Stores an encrypted secret in the runtime's store; returns metadata, never the value."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "secrets.set"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def handle(params, _ctx), do: LemonControlPlane.Methods.SecretsSupport.set(params)
end

defmodule LemonControlPlane.Methods.SecretsDelete do
  @moduledoc "Deletes an encrypted secret from the runtime's store."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "secrets.delete"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def handle(params, _ctx), do: LemonControlPlane.Methods.SecretsSupport.delete(params)
end
