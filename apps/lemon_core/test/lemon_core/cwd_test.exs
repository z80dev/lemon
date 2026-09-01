defmodule LemonCore.CwdTest do
  use ExUnit.Case, async: false

  alias LemonCore.Cwd

  # The gateway config's test-mode replacement layer, read by
  # LemonCore.GatewayConfig when config_test_mode is on (it is, in test).
  @replacement_key :"Elixir.LemonGateway.Config"

  setup do
    original = Application.get_env(:lemon_gateway, @replacement_key)
    Application.delete_env(:lemon_gateway, @replacement_key)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_gateway, @replacement_key)
      else
        Application.put_env(:lemon_gateway, @replacement_key, original)
      end
    end)

    :ok
  end

  test "uses the configured gateway default_cwd when it exists" do
    home = System.user_home() || System.tmp_dir!()
    configured = Path.join(home, "workspace")
    File.mkdir_p!(configured)

    Application.put_env(:lemon_gateway, @replacement_key, %{default_cwd: configured})

    assert Cwd.default_cwd() == Path.expand(configured)
  end

  test "falls back to home when the configured default_cwd is missing" do
    configured = Path.join(System.tmp_dir!(), "lemon-core-missing-default-cwd")
    File.rm_rf!(configured)

    Application.put_env(:lemon_gateway, @replacement_key, %{default_cwd: configured})

    assert Cwd.default_cwd() == expected_home_fallback()
  end

  test "a keyword config without default_cwd falls back without crashing" do
    Application.put_env(:lemon_gateway, @replacement_key, max_concurrent_runs: 1)

    assert Cwd.default_cwd() == expected_home_fallback()
  end

  defp expected_home_fallback do
    case System.user_home() do
      home when is_binary(home) and home != "" ->
        if File.dir?(home), do: Path.expand(home), else: File.cwd!()

      _ ->
        File.cwd!()
    end
  end
end
