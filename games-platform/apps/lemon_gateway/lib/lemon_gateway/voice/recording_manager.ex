defmodule LemonGateway.Voice.RecordingManager do
  @moduledoc """
  Manages call recordings via the Twilio REST API.

  Starts dual-channel recording when a call's media stream connects,
  and registers a status callback so the recording is auto-downloaded
  when the call ends.

  ## How it works

  1. `CallSession` calls `start_recording/2` when the Twilio WebSocket connects
  2. This module POSTs to the Twilio Recordings API to begin recording
  3. When the call ends, Twilio POSTs the recording status to our callback
  4. `WebhookRouter` receives the callback and triggers `RecordingDownloader`
  """

  require Logger

  alias LemonGateway.Voice.Config

  @doc """
  Starts dual-channel recording for the given call.

  `opts` may include:
  - `:recording_callback_url` - the full URL for Twilio to POST recording status to.
     If omitted, Twilio won't notify us (we'd have to poll).

  Returns `{:ok, recording_sid}` or `{:error, reason}`.
  """
  @spec start_recording(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_recording(call_sid, opts \\ []) do
    account_sid = Config.twilio_account_sid()
    auth_token = Config.twilio_auth_token()

    if is_nil(account_sid) or is_nil(auth_token) do
      {:error, :missing_twilio_credentials}
    else
      do_start_recording(call_sid, account_sid, auth_token, opts)
    end
  end

  # Private

  defp do_start_recording(call_sid, account_sid, auth_token, opts) do
    url =
      "https://api.twilio.com/2010-04-01/Accounts/#{account_sid}" <>
        "/Calls/#{call_sid}/Recordings.json"

    credentials = Base.encode64("#{account_sid}:#{auth_token}")

    headers = [
      {~c"authorization", String.to_charlist("Basic #{credentials}")},
      {~c"content-type", ~c"application/x-www-form-urlencoded"}
    ]

    # Build form body
    form_params = [
      {"RecordingChannels", "dual"},
      {"RecordingTrack", "both"},
      {"Trim", "do-not-trim"}
    ]

    form_params =
      case Keyword.get(opts, :recording_callback_url) do
        nil -> form_params
        url -> form_params ++ [{"RecordingStatusCallback", url}]
      end

    body = URI.encode_query(form_params)

    Logger.info("Starting recording for call #{call_sid}")

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded",
            String.to_charlist(body)},
           [timeout: 10_000],
           []
         ) do
      {:ok, {{_, status, _}, _headers, response_body}} when status in 200..201 ->
        response = Jason.decode!(IO.iodata_to_binary(response_body))
        recording_sid = response["sid"]
        Logger.info("Recording started: #{recording_sid} for call #{call_sid}")
        {:ok, recording_sid}

      {:ok, {{_, status, _}, _headers, response_body}} ->
        body_str = IO.iodata_to_binary(response_body)
        Logger.error("Failed to start recording for #{call_sid}: HTTP #{status} - #{body_str}")
        {:error, {:http_error, status, body_str}}

      {:error, reason} ->
        Logger.error("Failed to start recording for #{call_sid}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
