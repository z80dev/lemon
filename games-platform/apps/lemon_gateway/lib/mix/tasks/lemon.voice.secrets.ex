defmodule Mix.Tasks.Lemon.Voice.Secrets do
  use Mix.Task

  alias LemonCore.Secrets

  @shortdoc "Interactively set voice API secrets"
  @moduledoc """
  Interactively prompts for and stores all voice API secrets in the
  encrypted secrets store.

  Usage:
      mix lemon.voice.secrets

  Sets the following secrets:
    - twilio_account_sid
    - twilio_auth_token
    - deepgram_api_key
    - elevenlabs_api_key

  Existing values are preserved unless you enter a new one (press Enter to skip).
  """

  @voice_secrets [
    {"twilio_account_sid", "Twilio Account SID"},
    {"twilio_auth_token", "Twilio Auth Token"},
    {"deepgram_api_key", "Deepgram API Key"},
    {"elevenlabs_api_key", "ElevenLabs API Key"}
  ]

  @impl true
  def run(_args) do
    start_lemon_core!()

    Mix.shell().info("Voice Secrets Setup")
    Mix.shell().info("=" |> String.duplicate(40))
    Mix.shell().info("Enter each secret value, or press Enter to skip.\n")

    results =
      Enum.map(@voice_secrets, fn {name, label} ->
        existing = Secrets.exists?(name)
        hint = if existing, do: " (already set, Enter to keep)", else: ""
        prompt = "#{label}#{hint}: "

        value =
          prompt
          |> Mix.shell().prompt()
          |> String.trim()

        cond do
          value == "" and existing ->
            Mix.shell().info("  Kept existing #{name}")
            :skipped

          value == "" ->
            Mix.shell().info("  Skipped #{name}")
            :skipped

          true ->
            case Secrets.set(name, value, provider: "voice_setup") do
              {:ok, _} ->
                Mix.shell().info("  Stored #{name}")
                :stored

              {:error, reason} ->
                Mix.shell().error("  Failed to store #{name}: #{inspect(reason)}")
                :error
            end
        end
      end)

    stored = Enum.count(results, &(&1 == :stored))
    Mix.shell().info("\nDone. #{stored} secret(s) stored.")
  end

  defp start_lemon_core! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
