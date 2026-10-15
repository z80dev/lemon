defmodule LemonSkills.Tools.ToolDeadlinesTest do
  use ExUnit.Case, async: true
  alias LemonSkills.Tools

  test "media and peer tools retain their own worker or client deadlines" do
    for module <- [
          Tools.MediaAnalyzeImage,
          Tools.MediaGenerateImage,
          Tools.MediaGenerateSpeech,
          Tools.MediaGenerateVideo,
          Tools.MediaTranscribeAudio,
          Tools.Peer
        ] do
      assert module.tool("/tmp", []).timeout_ms == :infinity
    end

    for module <- [Tools.MediaStatus, Tools.Goal, Tools.Kanban] do
      assert module.tool("/tmp", []).timeout_ms == nil
    end
  end
end
