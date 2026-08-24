defmodule LemonControlPlane.Methods.UpdateRun do
  @moduledoc """
  Handler for the `update.run` control plane method.

  Built on `LemonCore.Update.Remote`: `checkOnly` (the default) reports what
  is published without downloading anything; `force` stages a new version if
  one is available (never restarts the node — the caller is responsible for
  triggering a restart once `restartRequired` comes back `true`).

  ## Configuration

  `LemonControlPlane.UpdateStore`'s `update_url` becomes a `base_url`
  override for `LemonCore.Update.Remote` (test/self-hosted-mirror seam); the
  key name is unchanged for backward compatibility. Without it, `Remote` uses
  its own default (the public GitHub releases host):

  ```elixir
  LemonControlPlane.UpdateStore.put_config(%{update_url: "https://example.test"})
  ```
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.UpdateStore
  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.Update.Remote

  @impl true
  def name, do: "update.run"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    force = params["force"] == true
    check_only = params["checkOnly"] == true or params["check_only"] == true
    apply? = force and not check_only

    remote_opts = remote_opts(params)

    result = if apply?, do: Remote.apply(remote_opts), else: Remote.check(remote_opts)

    case result do
      {:ok, info} ->
        response = response(info, apply?)
        {:ok, Map.put(response, "summary", summary(response, force, check_only))}

      {:error, reason} ->
        {:error, Errors.internal_error("Failed to check for updates: #{redact(reason)}")}
    end
  end

  defp remote_opts(params) do
    []
    |> maybe_put(:base_url, base_url_override())
    |> maybe_put(:channel, params["channel"])
    |> maybe_put(:version, params["version"])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp base_url_override do
    config = UpdateStore.get_config() || %{}
    get_field(config, :update_url)
  end

  defp configured? do
    case base_url_override() do
      value when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  defp response(%{staged: staged} = info, true) do
    %{
      "currentVersion" => info.current,
      "latestVersion" => info.latest || info.current,
      "updateAvailable" => not is_nil(staged),
      "updateApplied" => not is_nil(staged),
      "staged" => not is_nil(staged),
      "restartRequired" => info.restart_required == true,
      "message" => apply_message(staged)
    }
  end

  defp response(info, false) do
    %{
      "currentVersion" => info.current,
      "latestVersion" => info.latest || info.current,
      "updateAvailable" => info.update_available? == true,
      "updateApplied" => false,
      "staged" => false,
      "restartRequired" => false,
      "message" => check_message(info.update_available? == true)
    }
  end

  defp apply_message(nil), do: "Already running the latest version."
  defp apply_message(version), do: "Update staged to #{version}. Restart to apply."

  defp check_message(true), do: "Update available. Use force=true to apply."
  defp check_message(false), do: "Already running the latest version."

  defp summary(response, force, check_only) do
    %{
      "action" => name(),
      "configured" => configured?(),
      "force" => force,
      "checkOnly" => check_only,
      "currentVersion" => Map.get(response, "currentVersion"),
      "latestVersion" => Map.get(response, "latestVersion"),
      "updateAvailable" => Map.get(response, "updateAvailable") == true,
      "updateApplied" => Map.get(response, "updateApplied") == true,
      "messageReturned" => not is_nil(Map.get(response, "message")),
      "cleanup" => %{
        "includesDownloadUrl" => false,
        "includesChecksum" => false,
        "includesDownloadedBytes" => false,
        "includesCredentialValues" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp redact({:checksum_mismatch, _}), do: "checksum verification failed"
  defp redact(reason), do: inspect(reason)

  # Safe map access supporting both atom and string keys
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
