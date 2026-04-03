defmodule LemonCore.EngineCatalogTest do
  use ExUnit.Case, async: true

  alias LemonCore.EngineCatalog

  setup do
    original = Application.get_env(:lemon_core, :known_engines)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_core, :known_engines)
      else
        Application.put_env(:lemon_core, :known_engines, original)
      end
    end)

    :ok
  end

  test "uses default known engine ids" do
    Application.delete_env(:lemon_core, :known_engines)

    assert EngineCatalog.list_ids() == [
             "lemon",
             "echo",
             "codex",
             "claude",
             "droid",
             "opencode",
             "pi",
             "kimi"
           ]

    assert EngineCatalog.normalize(" Claude ") == "claude"
    assert EngineCatalog.known?("echo")
    refute EngineCatalog.known?("unknown")
  end

  test "respects configured known engine ids" do
    Application.put_env(:lemon_core, :known_engines, ["Codex", "custom", "custom", ""])

    assert EngineCatalog.list_ids() == ["codex", "custom"]
    assert EngineCatalog.normalize("custom") == "custom"
    refute EngineCatalog.known?("claude")
  end
end
