defmodule LemonAi.Models.CurrentCatalogTest do
  use ExUnit.Case, async: true

  alias LemonAi.Models

  test "unsupported live, image-output and alternate Vertex protocols stay excluded" do
    assert Models.get_model(:openai, "gpt-realtime-2.1") == nil

    for id <- ~w(gemini-live-2.5-flash gemini-live-2.5-flash-preview-native-audio
                 gemini-3.1-flash-live-preview gemini-3.1-flash-lite-image
                 deep-research-preview-04-2026 deep-research-max-preview-04-2026) do
      assert Models.get_model(:google, id) == nil
    end

    assert Enum.all?(Models.get_models(:google_vertex), &(&1.api == :google_vertex))
  end
end
