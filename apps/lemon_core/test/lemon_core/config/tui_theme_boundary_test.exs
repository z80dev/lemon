defmodule LemonCore.Config.TuiThemeBoundaryTest do
  @moduledoc """
  Boundary with the Bun terminal client (#640): `/theme` persists `[tui] theme`
  and every config load validates it, so a value the client writes that core
  rejects would break every `LemonCore.Config.cached/1` reader and the next
  daemon start. `test/fixtures/tui_theme_values.json` lists what the client
  persists or reads; `clients/tui/test/commands/theme.test.ts` asserts every
  `/theme` value is listed there.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Config.Modular

  @fixture Path.expand("../../fixtures/tui_theme_values.json", __DIR__)

  setup do
    previous_home = System.get_env("HOME")

    home =
      Path.join(System.tmp_dir!(), "tui_theme_boundary_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(home, ".lemon"))
    System.put_env("HOME", home)

    on_exit(fn ->
      if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME")
      LemonCore.ConfigCache.clear()
      File.rm_rf!(home)
    end)

    %{config_path: Path.join([home, ".lemon", "config.toml"])}
  end

  test "core loads every theme value the terminal client persists", %{config_path: path} do
    values = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("values")
    assert "auto" in values and "system" in values

    for value <- values do
      assert {:ok, %{tui: %{theme: ^value}}} =
               Modular.validate_settings(%{"tui" => %{"theme" => value}})

      File.write!(path, "[tui]\ntheme = \"#{value}\"\n")
      LemonCore.ConfigCache.clear()
      assert LemonCore.Config.cached().tui.theme == value
    end
  end

  test "/theme auto: a config with [tui] theme = \"auto\" loads", %{config_path: path} do
    File.write!(path, "[tui]\ntheme = \"auto\"\n")
    LemonCore.ConfigCache.clear()

    assert LemonCore.Config.reload().tui.theme == "auto"
    assert {:ok, _config} = Modular.load_with_validation()
  end
end
