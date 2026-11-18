defmodule LemonGateway.Voice.RecordingDownloader do
  @moduledoc """
  Downloads Twilio call recordings to a local directory.

  Recordings are saved as:
    <recordings_dir>/<YYYY-MM-DD>/<CallSid>_<from>_<duration>s.wav

  Every filename component is sanitized, so caller-supplied values cannot
  escape the recordings directory.

  Uses Twilio basic auth (AccountSid:AuthToken) to fetch the recording. The
  credentials are only ever sent to `https://api.twilio.com`; any other
  `RecordingUrl` is refused without a request. Every request goes through
  `LemonCore.Net.HTTP` (address re-authorized and pinned per hop). Redirects
  are not followed automatically: a redirect is followed (without credentials)
  only when it stays on `https://api.twilio.com`. Each hop has a 120 s
  deadline and the body is streamed to a temporary file beside the recording,
  cut off above 512 MiB, and renamed into place only when complete.
  """

  require Logger

  alias LemonCore.Net.HTTP
  alias LemonGateway.Voice.Config

  @twilio_api_host "api.twilio.com"
  @max_redirects 3
  @timeout_ms 120_000
  @max_recording_bytes 512 * 1024 * 1024

  @doc """
  Downloads a recording from Twilio and saves it locally.

  Returns `{:ok, local_path}` or `{:error, reason}`. `net_opts` are extra
  `LemonCore.Net.HTTP` options for tests (`:resolver`, `:send`); the
  destination, deadline and size cap cannot be overridden.
  """
  @spec download(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def download(params, net_opts \\ []) do
    recording_url = params["RecordingUrl"]
    recording_sid = params["RecordingSid"]
    call_sid = params["CallSid"]

    with {:ok, url} <- validate_recording_url(recording_url) do
      local_path = recording_path(params)
      File.mkdir_p!(Path.dirname(local_path))
      partial = "#{local_path}.part-#{System.unique_integer([:positive])}"

      # Twilio recording URL without extension returns WAV by default
      # Add .wav explicitly to be safe
      full_url = if String.ends_with?(url.path || "", ".wav"), do: url, else: wav_url(url)

      Logger.info(
        "Downloading recording #{inspect(recording_sid)} for call #{inspect(call_sid)} -> #{local_path}"
      )

      credentials = Base.encode64("#{Config.twilio_account_sid()}:#{Config.twilio_auth_token()}")
      headers = [{"authorization", "Basic #{credentials}"}]

      result =
        with :ok <- fetch(full_url, headers, @max_redirects, partial, net_opts),
             :ok <- File.rename(partial, local_path) do
          {:ok, local_path}
        end

      case result do
        {:ok, _path} ->
          Logger.info("Recording saved: #{local_path} (#{File.stat!(local_path).size} bytes)")
          result

        {:error, reason} = err ->
          File.rm(partial)

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

  # Redirects are handled manually: credentials go only on the first request,
  # and a redirect is only followed while it stays on https://api.twilio.com.
  defp fetch(%URI{} = url, headers, redirects_left, into, net_opts) do
    opts =
      Keyword.merge(net_opts,
        headers: headers,
        timeout_ms: @timeout_ms,
        max_body_bytes: @max_recording_bytes,
        max_redirects: 0,
        into: into
      )

    case HTTP.request(:get, URI.to_string(url), opts) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, headers: resp_headers}}
      when status in [301, 302, 303, 307, 308] ->
        follow_redirect(url, resp_headers, redirects_left, into, net_opts)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_redirect(_url, _headers, 0, _into, _net_opts), do: {:error, :too_many_redirects}

  defp follow_redirect(url, resp_headers, redirects_left, into, net_opts) do
    location =
      Enum.find_value(resp_headers, fn {k, v} ->
        if String.downcase(to_string(k)) == "location", do: to_string(v)
      end)

    with true <- is_binary(location) || {:error, :redirect_without_location},
         target = URI.merge(url, location),
         true <- twilio_api_uri?(target) || {:error, {:redirect_not_allowed, location}} do
      fetch(target, [], redirects_left - 1, into, net_opts)
    end
  end
end
