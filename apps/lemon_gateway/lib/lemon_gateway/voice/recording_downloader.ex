defmodule LemonGateway.Voice.RecordingDownloader do
  @moduledoc """
  Downloads Twilio call recordings to a local directory.

  Recordings are saved as:
    <recordings_dir>/<YYYY-MM-DD>/<CallSid>_<from>_<duration>s.wav

  Uses Twilio basic auth (AccountSid:AuthToken) to fetch the recording.
  """

  require Logger

  alias LemonGateway.Voice.Config

  @doc """
  Downloads a recording from Twilio and saves it locally.

  Returns `{:ok, local_path}` or `{:error, reason}`.
  """
  @spec download(map()) :: {:ok, String.t()} | {:error, term()}
  def download(params) do
    recording_url = params["RecordingUrl"]
    recording_sid = params["RecordingSid"]
    call_sid = params["CallSid"]
    from_number = params["From"] || "unknown"
    duration = params["RecordingDuration"] || "0"

    if is_nil(recording_url) or recording_url == "" do
      {:error, :no_recording_url}
    else
      dir = ensure_recordings_dir()
      sanitized_from = sanitize_filename(from_number)
      filename = "#{call_sid}_#{sanitized_from}_#{duration}s.wav"
      local_path = Path.join(dir, filename)

      # Twilio recording URL without extension returns WAV by default
      # Add .wav explicitly to be safe
      full_url =
        if String.ends_with?(recording_url, ".wav") do
          recording_url
        else
          recording_url <> ".wav"
        end

      # Twilio requires basic auth for recording downloads
      account_sid = Config.twilio_account_sid()
      auth_token = Config.twilio_auth_token()

      Logger.info(
        "Downloading recording #{recording_sid} for call #{call_sid} " <>
          "(#{duration}s from #{from_number}) -> #{local_path}"
      )

      case download_with_auth(full_url, account_sid, auth_token) do
        {:ok, audio_data} ->
          File.write!(local_path, audio_data)

          Logger.info(
            "Recording saved: #{local_path} (#{byte_size(audio_data)} bytes)"
          )

          {:ok, local_path}

        {:error, reason} = err ->
          Logger.error(
            "Failed to download recording #{recording_sid}: #{inspect(reason)}"
          )

          err
      end
    end
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

  defp ensure_recordings_dir do
    date_str = Date.utc_today() |> Date.to_iso8601()
    dir = Path.join(recordings_dir(), date_str)
    File.mkdir_p!(dir)
    dir
  end

  defp default_recordings_dir do
    Path.expand("~/.lemon/recordings")
  end

  defp sanitize_filename(str) do
    str
    |> String.replace(~r/[^a-zA-Z0-9_\-+]/, "_")
    |> String.slice(0, 30)
  end

  defp download_with_auth(url, account_sid, auth_token) do
    # Build basic auth header
    credentials = Base.encode64("#{account_sid}:#{auth_token}")

    headers = [
      {~c"authorization", String.to_charlist("Basic #{credentials}")}
    ]

    # Twilio may redirect — :httpc follows redirects by default with autoredirect
    case :httpc.request(
           :get,
           {String.to_charlist(url), headers},
           [timeout: 30_000, autoredirect: true],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, {:http_error, status, IO.iodata_to_binary(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
