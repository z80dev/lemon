defmodule LemonGateway.Voice.RecordingDownloader do
  @moduledoc """
  Downloads Twilio call recordings to a local directory.

  Recordings are saved as:
    <recordings_dir>/<YYYY-MM-DD>/<CallSid>_<from>_<duration>s.wav

  Every filename component is sanitized, so caller-supplied values cannot
  escape the recordings directory.

  Uses Twilio basic auth (AccountSid:AuthToken) to fetch the recording. The
  credentials are only ever sent to `https://api.twilio.com`; any other
  `RecordingUrl` is refused without a request. Redirects are not followed
  automatically: a redirect is followed (without credentials) only when it stays
  on `https://api.twilio.com`.
  """

  require Logger

  alias LemonCore.Httpc
  alias LemonGateway.Voice.Config

  @twilio_api_host "api.twilio.com"
  @max_redirects 3

  @doc """
  Downloads a recording from Twilio and saves it locally.

  Returns `{:ok, local_path}` or `{:error, reason}`.
  """
  @spec download(map()) :: {:ok, String.t()} | {:error, term()}
  def download(params) do
    recording_url = params["RecordingUrl"]
    recording_sid = params["RecordingSid"]
    call_sid = params["CallSid"]

    with {:ok, url} <- validate_recording_url(recording_url) do
      local_path = recording_path(params)
      File.mkdir_p!(Path.dirname(local_path))

      # Twilio recording URL without extension returns WAV by default
      # Add .wav explicitly to be safe
      full_url = if String.ends_with?(url.path || "", ".wav"), do: url, else: wav_url(url)

      Logger.info(
        "Downloading recording #{inspect(recording_sid)} for call #{inspect(call_sid)} -> #{local_path}"
      )

      case download_with_auth(full_url, Config.twilio_account_sid(), Config.twilio_auth_token()) do
        {:ok, audio_data} ->
          File.write!(local_path, audio_data)

          Logger.info("Recording saved: #{local_path} (#{byte_size(audio_data)} bytes)")

          {:ok, local_path}

        {:error, reason} = err ->
          Logger.error(
            "Failed to download recording #{inspect(recording_sid)}: #{inspect(reason)}"
          )

          err
      end
    end
  end

  @doc """
  Returns the local path a recording described by Twilio callback `params`
  is saved to. Every component is sanitized to stay inside `recordings_dir/0`.
  """
  @spec recording_path(map()) :: String.t()
  def recording_path(params) do
    call_sid = sanitize_filename(params["CallSid"] || "unknown")
    from = sanitize_filename(params["From"] || "unknown")
    duration = sanitize_duration(params["RecordingDuration"])
    date_str = Date.utc_today() |> Date.to_iso8601()

    Path.join([recordings_dir(), date_str, "#{call_sid}_#{from}_#{duration}s.wav"])
  end

  @doc """
  Returns the base recordings directory path.
  """
  @spec recordings_dir() :: String.t()
  def recordings_dir do
    Application.get_env(:lemon_gateway, :voice_recordings_dir) ||
      System.get_env("VOICE_RECORDINGS_DIR") ||
      default_recordings_dir()
  end

  # Private

  defp default_recordings_dir do
    Path.expand("~/.lemon/recordings")
  end

  defp sanitize_filename(str) when is_binary(str) do
    str
    |> String.replace(~r/[^a-zA-Z0-9_\-+]/, "_")
    |> String.slice(0, 40)
  end

  defp sanitize_filename(_), do: "unknown"

  defp sanitize_duration(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> Integer.to_string(n)
      _ -> "0"
    end
  end

  defp sanitize_duration(_), do: "0"

  defp validate_recording_url(url) when is_binary(url) and url != "" do
    case URI.new(url) do
      {:ok, %URI{} = uri} ->
        if twilio_api_uri?(uri), do: {:ok, uri}, else: {:error, {:recording_url_not_allowed, url}}

      {:error, _} ->
        {:error, {:recording_url_not_allowed, url}}
    end
  end

  defp validate_recording_url(_), do: {:error, :no_recording_url}

  defp twilio_api_uri?(%URI{scheme: "https", host: host, userinfo: nil, port: 443})
       when is_binary(host),
       do: String.downcase(host) == @twilio_api_host

  defp twilio_api_uri?(_), do: false

  defp wav_url(%URI{path: path} = uri), do: %URI{uri | path: (path || "") <> ".wav"}

  defp download_with_auth(%URI{} = url, account_sid, auth_token) do
    credentials = Base.encode64("#{account_sid}:#{auth_token}")
    headers = [{~c"authorization", String.to_charlist("Basic #{credentials}")}]
    fetch(url, headers, @max_redirects)
  end

  # Redirects are handled manually: credentials go only on the first request,
  # and a redirect is only followed while it stays on https://api.twilio.com.
  defp fetch(%URI{} = url, headers, redirects_left) do
    case Httpc.request(
           :get,
           {String.to_charlist(URI.to_string(url)), headers},
           [timeout: 30_000, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, {{_, status, _}, resp_headers, _body}} when status in [301, 302, 303, 307, 308] ->
        follow_redirect(url, resp_headers, redirects_left)

      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, {:http_error, status, IO.iodata_to_binary(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_redirect(_url, _headers, 0), do: {:error, :too_many_redirects}

  defp follow_redirect(url, resp_headers, redirects_left) do
    location =
      Enum.find_value(resp_headers, fn {k, v} ->
        if String.downcase(to_string(k)) == "location", do: to_string(v)
      end)

    with true <- is_binary(location) || {:error, :redirect_without_location},
         target = URI.merge(url, location),
         true <- twilio_api_uri?(target) || {:error, {:redirect_not_allowed, location}} do
      fetch(target, [], redirects_left - 1)
    end
  end
end
