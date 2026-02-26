defmodule LemonGateway.Transports.Voice do
  @moduledoc """
  Voice transport for LemonGateway using Twilio Media Streams.

  Enables phone calls where users can talk to zeebot:
  - User dials a Twilio phone number
  - Twilio connects via Media Streams WebSocket
  - Audio flows: Twilio → Deepgram (STT) → LLM → ElevenLabs (TTS) → Twilio
  """

  use GenServer
  use LemonGateway.Transport

  require Logger

  alias LemonGateway.Voice.Config

  @impl LemonGateway.Transport
  def id, do: "voice"

  @impl LemonGateway.Transport
  def start_link(_opts) do
    if Config.enabled?() do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    else
      Logger.info("Voice transport disabled")
      :ignore
    end
  end

  @impl GenServer
  def init(_opts) do
    Logger.info("Starting voice transport")

    # Validate configuration
    case validate_config() do
      :ok ->
        # Start supervision tree for voice calls
        start_voice_supervisors()

        # Start HTTP server for Twilio webhooks
        start_webhook_server()

        Logger.info("Voice transport started on port #{Config.websocket_port()}")
        {:ok, %{}}

      {:error, reason} ->
        Logger.error("Voice transport configuration error: #{reason}")
        {:stop, {:configuration_error, reason}}
    end
  end

  # Private Functions

  defp validate_config do
    checks = [
      {:twilio_account_sid, Config.twilio_account_sid()},
      {:twilio_auth_token, Config.twilio_auth_token()},
      {:twilio_phone_number, Config.twilio_phone_number()},
      {:deepgram_api_key, Config.deepgram_api_key()},
      {:elevenlabs_api_key, Config.elevenlabs_api_key()}
    ]

    missing =
      checks
      |> Enum.filter(fn {_name, value} -> is_nil(value) or value == "" end)
      |> Enum.map(fn {name, _} -> name end)

    if missing == [] do
      :ok
    else
      {:error, "Missing configuration: #{Enum.join(missing, ", ")}"}
    end
  end

  defp start_voice_supervisors do
    # Registry for call sessions
    Registry.start_link(
      keys: :unique,
      name: LemonGateway.Voice.CallRegistry
    )

    Registry.start_link(
      keys: :unique,
      name: LemonGateway.Voice.DeepgramRegistry
    )

    # Dynamic supervisors for call processes
    DynamicSupervisor.start_link(
      name: LemonGateway.Voice.CallSessionSupervisor,
      strategy: :one_for_one
    )

    DynamicSupervisor.start_link(
      name: LemonGateway.Voice.DeepgramSupervisor,
      strategy: :one_for_one
    )

    :ok
  end

  defp start_webhook_server do
    port = Config.websocket_port()

    children = [
      {
        Bandit,
        plug: LemonGateway.Voice.WebhookRouter,
        port: port,
        scheme: :http
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
