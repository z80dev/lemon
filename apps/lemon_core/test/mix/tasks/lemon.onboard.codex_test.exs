defmodule Mix.Tasks.Lemon.Onboard.CodexTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCore.Secrets
  alias Mix.Tasks.Lemon.Onboard.Codex

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "lemon_onboard_codex_#{System.unique_integer([:positive])}")

    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    original_home = System.get_env("HOME")
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")

    System.put_env("HOME", mock_home)
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_master_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", original_master_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")

      clear_secrets_table()
      File.rm_rf!(tmp_dir)
    end)

    clear_secrets_table()

    {:ok, tmp_dir: tmp_dir}
  end

  test "stores token and updates providers config", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    output =
      capture_io(fn ->
        Codex.run([
          "--token",
          "codex-token-123",
          "--config-path",
          config_path
        ])
      end)

    assert output =~ "OpenAI Codex onboarding complete."

    assert {:ok, "codex-token-123"} =
             Secrets.get("llm_openai_codex_api_key", prefer_env: false, env_fallback: false)

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "openai-codex", "api_key_secret"]) ==
             "llm_openai_codex_api_key"

    refute Map.has_key?(config_map, "defaults")
  end

  test "sets defaults when --set-default is enabled", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    capture_io(fn ->
      Codex.run([
        "--token",
        "codex-token-123",
        "--config-path",
        config_path,
        "--set-default",
        "--model",
        "gpt-5.2"
      ])
    end)

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "openai-codex", "api_key_secret"]) ==
             "llm_openai_codex_api_key"

    assert get_in(config_map, ["defaults", "provider"]) == "openai-codex"
    assert get_in(config_map, ["defaults", "model"]) == "openai-codex:gpt-5.2"
  end

  test "raises for unknown explicit model", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    assert_raise Mix.Error, ~r/Unknown model/, fn ->
      capture_io(fn ->
        Codex.run([
          "--token",
          "codex-token-123",
          "--config-path",
          config_path,
          "--set-default",
          "--model",
          "not-a-real-model"
        ])
      end)
    end
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
