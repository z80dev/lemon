defmodule Mix.Tasks.Lemon.ProvidersTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Providers

  @env_keys ~w(ANTHROPIC_API_KEY OPENAI_API_KEY ZAI_API_KEY)

  setup do
    saved_env = Map.new(@env_keys, fn key -> {key, System.get_env(key)} end)
    Enum.each(@env_keys, &System.delete_env/1)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_providers_task_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(tmp_dir)
    end)

    %{cwd: tmp_dir}
  end

  test "renders redacted provider readiness", %{cwd: cwd} do
    write_config!(cwd, """
    [defaults]
    provider = "openai"
    model = "gpt-5-mini"
    """)

    System.put_env("OPENAI_API_KEY", "openai-secret-value")

    output =
      capture_io(fn ->
        Providers.run(["--provider", "openai", "--project-dir", cwd])
      end)

    assert output =~ "Lemon Providers"
    assert output =~ "Providers: "
    assert output =~ "Ready: "
    assert output =~ "Includes raw API keys: false"
    assert output =~ "Includes secret names: false"
    assert output =~ "Includes raw base URLs: false"
    assert output =~ "Includes env var names: false"
    assert output =~ "credential_ready: true"
    refute output =~ "openai-secret-value"
    refute output =~ "OPENAI_API_KEY"
  end

  defp write_config!(cwd, body) do
    cwd
    |> Path.join(".lemon/config.toml")
    |> File.write!(body)
  end
end
