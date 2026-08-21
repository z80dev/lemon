defmodule LemonChannels.EngineRegistryTest do
  use ExUnit.Case, async: false

  alias LemonChannels.EngineRegistry
  alias LemonCore.{ResumeFormat, ResumeFormats, ResumeToken}

  test "accepts a strict native resume line" do
    assert {:ok, %ResumeToken{engine: "lemon", value: "native-session-123"}} =
             EngineRegistry.extract_resume("Continue from this:\n`lemon resume native-session-123`\nThanks")
  end

  test "rejects registered vendor and generic custom resume lines" do
    ResumeFormats.register(
      ResumeFormat.new("vendor",
        pattern: ~r/vendor --continue <([^>]+)>/i,
        render: &("vendor --continue <" <> &1 <> ">")
      )
    )

    on_exit(fn -> ResumeFormats.unregister("vendor") end)

    assert :none = EngineRegistry.extract_resume("vendor --continue <vendor-session-123>")
    assert :none = EngineRegistry.extract_resume("custom resume custom-session-123")
  end

  test "does not treat native resume syntax embedded in prose as a selector" do
    assert :none = EngineRegistry.extract_resume("Please run lemon resume native-session-123")
  end
end
