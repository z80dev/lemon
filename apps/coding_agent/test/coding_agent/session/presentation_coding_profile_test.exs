defmodule CodingAgent.Session.PresentationCodingProfileTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Executor.RemoteRequestCodec
  alias CodingAgent.Session.{Presentation, PromptComposer}

  test "explicit coding and negative persona survive the native option allowlist" do
    meta = RemoteRequestCodec.normalize_meta(%{"session_mode" => "coding", "persona" => false})

    opts =
      Presentation.build_session_opts(
        Map.to_list(meta),
        "/project",
        "run",
        "agent:default:main",
        "default"
      )

    assert opts[:session_mode] == "coding"
    assert opts[:persona] == false
    assert PromptComposer.resolve_session_mode(opts) == :coding
  end
end
