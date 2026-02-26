defmodule LemonCore.Config.TUITest do
  @moduledoc """
  Tests for the Config.TUI module.
  """
  use LemonCore.Testing.Case, async: false

  alias LemonCore.Config.TUI

  setup do
    # Store original env vars to restore later
    original_env = System.get_env()

    on_exit(fn ->
      # Clear test env vars
      ["LEMON_TUI_THEME", "LEMON_TUI_DEBUG"]
      |> Enum.each(&System.delete_env/1)

      # Restore original values
      original_env
      |> Enum.each(fn {key, value} ->
        System.put_env(key, value)
      end)
    end)

    :ok
  end

  describe "resolve/1" do
    test "uses defaults when no settings provided" do
      config = TUI.resolve(%{})

      assert config.theme == "lemon"
      assert config.debug == false
    end

    test "uses settings from config map" do
      settings = %{
        "tui" => %{
          "theme" => "dark",
          "debug" => true
        }
      }

      config = TUI.resolve(settings)

      assert config.theme == "dark"
      assert config.debug == true
    end

    test "environment variables override settings" do
      System.put_env("LEMON_TUI_THEME", "ocean")
      System.put_env("LEMON_TUI_DEBUG", "true")

      settings = %{
        "tui" => %{
          "theme" => "light",
          "debug" => false
        }
      }

      config = TUI.resolve(settings)

      assert config.theme == "ocean"
      assert config.debug == true
    end
  end

  describe "theme configuration" do
    test "uses default theme" do
      config = TUI.resolve(%{})
      assert config.theme == "lemon"
    end

    test "uses theme from config" do
      config = TUI.resolve(%{"tui" => %{"theme" => "dark"}})
      assert config.theme == "dark"
    end

    test "env var overrides theme" do
      System.put_env("LEMON_TUI_THEME", "custom")
      config = TUI.resolve(%{"tui" => %{"theme" => "lemon"}})
      assert config.theme == "custom"
    end
  end

  describe "debug configuration" do
    test "uses default debug (false)" do
      config = TUI.resolve(%{})
      assert config.debug == false
    end

    test "uses debug from config" do
      config = TUI.resolve(%{"tui" => %{"debug" => true}})
      assert config.debug == true
    end

    test "env var overrides debug" do
      System.put_env("LEMON_TUI_DEBUG", "true")
      config = TUI.resolve(%{"tui" => %{"debug" => false}})
      assert config.debug == true
    end

    test "handles false value correctly" do
      config = TUI.resolve(%{"tui" => %{"debug" => false}})
      assert config.debug == false
    end
  end

  describe "defaults/0" do
    test "returns the default TUI configuration" do
      defaults = TUI.defaults()

      assert defaults["theme"] == "lemon"
      assert defaults["debug"] == false
    end
  end

  describe "struct type" do
    test "returns a properly typed struct" do
      config = TUI.resolve(%{})

      assert %TUI{} = config
      assert is_binary(config.theme)
      assert is_boolean(config.debug)
    end
  end
end
