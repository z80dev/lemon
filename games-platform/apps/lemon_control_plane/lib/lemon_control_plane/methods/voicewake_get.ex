defmodule LemonControlPlane.Methods.VoicewakeGet do
  @moduledoc """
  Handler for the voicewake.get control plane method.

  Returns the current voicewake (wake word detection) configuration.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "voicewake.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    config = LemonCore.Store.get(:voicewake_config, :global) || default_config()

    {:ok, %{
      "enabled" => config[:enabled] || false,
      "keyword" => config[:keyword] || "hey lemon",
      "sensitivity" => config[:sensitivity] || 0.5,
      "backend" => config[:backend] || "porcupine"
    }}
  end

  defp default_config do
    %{
      enabled: false,
      keyword: "hey lemon",
      sensitivity: 0.5,
      backend: "porcupine"
    }
  end
end
