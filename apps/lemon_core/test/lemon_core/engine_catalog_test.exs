defmodule LemonCore.EngineCatalogTest do
  # Both inputs to the catalog are application env, which is VM-global.
  use ExUnit.Case, async: false

  alias LemonCore.EngineCatalog

  setup do
    original = Application.fetch_env(:lemon_core, :known_engines)
    original_registered = Application.fetch_env(:lemon_core, :registered_engines)

    on_exit(fn ->
      restore(:known_engines, original)
      restore(:registered_engines, original_registered)
    end)

    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:lemon_core, key, value)
  defp restore(key, :error), do: Application.delete_env(:lemon_core, key)

  test "uses default known engine ids" do
    Application.delete_env(:lemon_core, :known_engines)
    Application.delete_env(:lemon_core, :registered_engines)

    assert EngineCatalog.list_ids() == [
             "lemon",
             "echo",
             "codex",
             "claude",
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

  test "registered engines extend the defaults" do
    Application.delete_env(:lemon_core, :known_engines)
    Application.put_env(:lemon_core, :registered_engines, ["vendor"])

    assert EngineCatalog.known?("vendor")
    assert EngineCatalog.known?("lemon")
  end

  test "a configured list is a ceiling registrations cannot widen" do
    Application.put_env(:lemon_core, :known_engines, ["lemon"])
    Application.put_env(:lemon_core, :registered_engines, ["vendor"])

    assert EngineCatalog.list_ids() == ["lemon"]
    refute EngineCatalog.known?("vendor")
  end
end
