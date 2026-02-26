defmodule LemonControlPlane.Methods.TtsStatus do
  @moduledoc """
  Handler for the tts.status control plane method.

  Returns the current text-to-speech configuration and status.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "tts.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    config = LemonCore.Store.get(:tts_config, :global) || default_config()

    {:ok, %{
      "enabled" => config[:enabled] || false,
      "provider" => config[:provider] || "system",
      "voice" => config[:voice],
      "rate" => config[:rate] || 1.0
    }}
  end

  defp default_config do
    %{
      enabled: false,
      provider: "system",
      voice: nil,
      rate: 1.0
    }
  end
end
