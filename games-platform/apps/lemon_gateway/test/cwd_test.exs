defmodule LemonGateway.CwdTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Cwd

  setup do
    original_override = Application.get_env(:lemon_gateway, LemonGateway.Config)
    original_config_path = Application.get_env(:lemon_gateway, :config_path)
    config_pid = Process.whereis(LemonGateway.Config)
    config_state = if is_pid(config_pid), do: :sys.get_state(LemonGateway.Config), else: nil

    Application.delete_env(:lemon_gateway, LemonGateway.Config)
    Application.delete_env(:lemon_gateway, :config_path)

    on_exit(fn ->
      if is_nil(original_override) do
        Application.delete_env(:lemon_gateway, LemonGateway.Config)
      else
        Application.put_env(:lemon_gateway, LemonGateway.Config, original_override)
      end

      if is_nil(original_config_path) do
        Application.delete_env(:lemon_gateway, :config_path)
      else
        Application.put_env(:lemon_gateway, :config_path, original_config_path)
      end

      if is_pid(config_pid) and is_map(config_state) do
        :sys.replace_state(LemonGateway.Config, fn _ -> config_state end)
      end
    end)

    :ok
  end

  test "uses configured gateway.default_cwd when it exists" do
    home = System.user_home() || System.tmp_dir!()
    configured = Path.join(home, "workspace")
    File.mkdir_p!(configured)

    set_default_cwd!(configured)

    assert Cwd.default_cwd() == Path.expand(configured)
  end

  test "falls back to home when configured gateway.default_cwd is missing" do
    configured = Path.join(System.tmp_dir!(), "lemon-gateway-missing-default-cwd")
    File.rm_rf!(configured)

    set_default_cwd!(configured)

    assert Cwd.default_cwd() == expected_home_fallback()
  end

  defp set_default_cwd!(cwd) do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      :sys.replace_state(LemonGateway.Config, fn state ->
        Map.put(state, :default_cwd, cwd)
      end)
    else
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{default_cwd: cwd})
    end
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
