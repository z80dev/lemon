defmodule LemonControlPlane.Methods.UpdateRun do
  @moduledoc """
  Handler for the update.run control plane method.

  Triggers a system update check and optionally applies updates.

  ## Configuration

  Configure update checking via store:
  ```elixir
  LemonCore.Store.put(:update_config, :global, %{
    update_url: "https://api.example.com/releases/latest",
    auto_restart: false
  })
  ```

  ## Update Manifest Format

  The update URL should return JSON:
  ```json
  {
    "version": "1.2.3",
    "releaseDate": "2025-01-15",
    "downloadUrl": "https://...",
    "changelog": "...",
    "checksum": "sha256:..."
  }
  ```
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  require Logger

  @impl true
  def name, do: "update.run"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    force = params["force"] || false
    check_only = params["checkOnly"] || params["check_only"] || false

    # Get current version info
    current_version = get_current_version()

    # Check if update checking is configured
    update_config = LemonCore.Store.get(:update_config, :global) || %{}
    update_url = get_field(update_config, :update_url)

    if is_nil(update_url) or update_url == "" do
      # No update URL configured - return current version info
      {:ok, %{
        "currentVersion" => current_version,
        "updateAvailable" => false,
        "latestVersion" => current_version,
        "message" => "Update checking not configured. Set update_url in update_config."
      }}
    else
      # Fetch latest version info from update URL
      case fetch_update_manifest(update_url) do
        {:ok, manifest} ->
          latest_version = manifest["version"] || manifest[:version] || current_version
          update_available = version_newer?(latest_version, current_version)

          result = %{
            "currentVersion" => current_version,
            "updateAvailable" => update_available,
            "latestVersion" => latest_version,
            "releaseDate" => manifest["releaseDate"] || manifest[:release_date],
            "changelog" => manifest["changelog"] || manifest[:changelog]
          }

          if update_available and force and not check_only do
            # Attempt to apply update
            case apply_update(manifest, update_config) do
              {:ok, message} ->
                {:ok, Map.merge(result, %{
                  "updateApplied" => true,
                  "message" => message
                })}

              {:error, reason} ->
                {:ok, Map.merge(result, %{
                  "updateApplied" => false,
                  "message" => "Update available but failed to apply: #{reason}"
                })}
            end
          else
            message = cond do
              not update_available -> "Already running latest version"
              check_only -> "Update available. Use force=true to apply."
              true -> "Update available. Use force=true to apply."
            end

            {:ok, Map.put(result, "message", message)}
          end

        {:error, reason} ->
          {:error, Errors.internal_error("Failed to check for updates: #{reason}")}
      end
    end
  end

  defp get_current_version do
    case Application.spec(:lemon_control_plane, :vsn) do
      nil -> "0.0.0"
      vsn when is_list(vsn) -> to_string(vsn)
      vsn -> to_string(vsn)
    end
  end

  defp fetch_update_manifest(url) do
    request = {String.to_charlist(url), []}

    case LemonCore.Httpc.request(:get, request, [timeout: 10_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, manifest} -> {:ok, manifest}
          {:error, _} -> {:error, "Invalid JSON response"}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, "HTTP #{status}: #{String.slice(to_string(body), 0, 100)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp version_newer?(latest, current) do
    case {Version.parse(normalize_version(latest)), Version.parse(normalize_version(current))} do
      {{:ok, latest_v}, {:ok, current_v}} ->
        Version.compare(latest_v, current_v) == :gt

      _ ->
        # If parsing fails, do string comparison
        latest != current and latest > current
    end
  end

  defp normalize_version(v) do
    # Remove 'v' prefix if present and ensure 3-part version
    v = String.trim_leading(to_string(v), "v")

    case String.split(v, ".") do
      [major] -> "#{major}.0.0"
      [major, minor] -> "#{major}.#{minor}.0"
      _ -> v
    end
  end

  defp apply_update(manifest, config) do
    download_url = manifest["downloadUrl"] || manifest[:download_url]
    checksum = manifest["checksum"] || manifest[:checksum]
    auto_restart = get_field(config, :auto_restart) || false

    cond do
      is_nil(download_url) ->
        {:error, "No download URL in manifest"}

      true ->
        # Download update
        case download_update(download_url, checksum) do
          {:ok, update_path} ->
            # Store update info for restart
            update_info = %{
              version: manifest["version"],
              path: update_path,
              downloaded_at: System.system_time(:millisecond)
            }
            LemonCore.Store.put(:pending_update, :current, update_info)

            if auto_restart do
              # Schedule restart
              spawn(fn ->
                Process.sleep(1000)
                Logger.info("Restarting for update to version #{manifest["version"]}")
                System.stop(0)
              end)
              {:ok, "Update downloaded. Restarting..."}
            else
              {:ok, "Update downloaded to #{update_path}. Restart to apply."}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp download_update(url, expected_checksum) do
    request = {String.to_charlist(url), []}

    case LemonCore.Httpc.request(:get, request, [timeout: 300_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        # Verify checksum if provided
        if expected_checksum do
          case verify_checksum(body, expected_checksum) do
            :ok ->
              save_update(body)

            {:error, reason} ->
              {:error, reason}
          end
        else
          save_update(body)
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "Download failed with HTTP #{status}"}

      {:error, reason} ->
        {:error, "Download failed: #{inspect(reason)}"}
    end
  end

  defp verify_checksum(data, expected) do
    case String.split(expected, ":", parts: 2) do
      ["sha256", hash] ->
        actual = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
        if actual == String.downcase(hash) do
          :ok
        else
          {:error, "Checksum mismatch"}
        end

      ["md5", hash] ->
        actual = :crypto.hash(:md5, data) |> Base.encode16(case: :lower)
        if actual == String.downcase(hash) do
          :ok
        else
          {:error, "Checksum mismatch"}
        end

      _ ->
        # Unknown checksum format, skip verification
        :ok
    end
  end

  defp save_update(data) do
    update_dir = Path.join(System.tmp_dir!(), "lemon_updates")
    File.mkdir_p!(update_dir)

    filename = "update_#{System.unique_integer([:positive])}.bin"
    path = Path.join(update_dir, filename)

    case File.write(path, data) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "Failed to save update: #{inspect(reason)}"}
    end
  end

  # Safe map access supporting both atom and string keys
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
