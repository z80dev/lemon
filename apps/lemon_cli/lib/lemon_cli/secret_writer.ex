defmodule LemonCli.SecretWriter do
  @moduledoc """
  The one place one-shot commands write encrypted secrets.

  A one-shot VM writes its own store only while no runtime owns it. When a
  running runtime owns the store (`LemonCore.Store.write_access/0` returns
  `{:error, :runtime_owned}`), the write goes to that runtime over the
  control plane (`secrets.set` / `secrets.delete`), so the CLI is never a
  second store writer and the runtime sees the change at once.

  Errors are the `LemonCore.Secrets` reasons, plus:

    * `:runtime_unreachable` - a runtime owns the store but its control plane
      did not answer before the request was sent; nothing was written.
    * `:outcome_unknown` - the request may have reached the runtime; the write
      may or may not have landed. Check before retrying.
  """

  alias LemonCore.Secrets

  @remote_timeout_ms 15_000

  # The bounded reasons `secrets.set` / `secrets.delete` report for a refusal.
  @remote_reasons Map.new(
                    ~w(missing_master_key weak_master_key master_key_mismatch
                       key_rotation_incomplete invalid_secret_name invalid_secret_value
                       secrets_locked stale_revision secret_store_failed)a,
                    &{Atom.to_string(&1), &1}
                  )
                  |> Map.put("keychain_failed", {:keychain_failed, :runtime})

  # Refused before any write: authentication, authorization and validation.
  @refused_codes ~w(UNAUTHORIZED FORBIDDEN PERMISSION_DENIED INVALID_REQUEST METHOD_NOT_FOUND)

  @spec set(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def set(name, value, opts \\ []) do
    case LemonCore.Store.write_access() do
      {:error, :runtime_owned} ->
        params =
          %{"name" => name, "value" => value}
          |> put_param("provider", opts[:provider])
          |> put_param("expiresAt", opts[:expires_at])

        with {:ok, result} <- remote("secrets.set", params) do
          {:ok, %{name: result["name"], owner: result["owner"], provider: result["provider"]}}
        end

      _local ->
        Secrets.set(name, value, opts)
    end
  end

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name) do
    case LemonCore.Store.write_access() do
      {:error, :runtime_owned} ->
        with {:ok, _result} <- remote("secrets.delete", %{"name" => name}), do: :ok

      _local ->
        Secrets.delete(name)
    end
  end

  defp remote(method, params) do
    client = Application.get_env(:lemon_cli, :control_plane_client, LemonCli.ControlPlaneClient)

    case client.request(method, params, timeout_ms: @remote_timeout_ms) do
      {:ok, result} -> {:ok, result}
      {:error, {:control_plane_unavailable, _}} -> {:error, :runtime_unreachable}
      {:error, {:control_plane, error}} -> {:error, remote_reason(error)}
      {:error, _sent_or_unknown} -> {:error, :outcome_unknown}
    end
  end

  # Only a refusal the runtime marks as not applied, or one made before the
  # handler ran, is a definite failure; anything else may have written.
  defp remote_reason(%{"details" => %{"mutationMayHaveApplied" => false, "reason" => reason}})
       when is_map_key(@remote_reasons, reason),
       do: Map.fetch!(@remote_reasons, reason)

  defp remote_reason(%{"code" => code}) when code in @refused_codes,
    do: {:runtime_refused, code}

  defp remote_reason(_error), do: :outcome_unknown

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: Map.put(params, key, value)
end
