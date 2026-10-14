defmodule LemonCli.Setup.ProviderAuthTest do
  # Mutates HOME, process env and the shared secrets table.
  use ExUnit.Case, async: false

  alias LemonCli.Onboarding.Runner
  alias LemonCli.Setup.Provider
  alias LemonCore.Secrets

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "provider_auth_#{System.unique_integer([:positive])}")
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)
    Runner.ensure_required_apps!()

    previous =
      Map.new(
        ~w(HOME LEMON_SECRETS_MASTER_KEY ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_TOKEN),
        &{&1, System.get_env(&1)}
      )

    System.put_env("HOME", home)
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    Enum.each(~w(ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_TOKEN), &System.delete_env/1)
    clear_secrets_table()

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      clear_secrets_table()
      File.rm_rf!(tmp_dir)
    end)

    config_path = Path.join(tmp_dir, "config.toml")

    File.write!(config_path, """
    # keep this comment
    [defaults]
    provider = "anthropic"

    [providers.anthropic]
    auth_source = "oauth"
    oauth_secret = "llm_anthropic_api_key"
    """)

    {:ok, config_path: config_path}
  end

  test "--status reports the stored login without printing tokens", %{config_path: config_path} do
    store_login()
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-api03-ignored")

    assert :ok = Provider.run(["anthropic", "--status", "--config-path", config_path], io())

    output = collected_output()
    assert output =~ "Auth source: oauth (subscription login)"

    assert output =~
             "Stored login: llm_anthropic_api_key (refreshable login, user@example.com, Personal)"

    assert output =~ "Access token: expires in 7h"
    assert output =~ "Sign in again by: "
    assert output =~ "ANTHROPIC_API_KEY: set, ignored while auth_source = \"oauth\""
    assert output =~ "Credentials usable: yes"
    refute output =~ "sk-ant-oat01"
    refute output =~ "sk-ant-ort01"
    refute output =~ "sk-ant-api03"
  end

  test "--logout deletes the login and removes only the OAuth config keys", %{
    config_path: config_path
  } do
    store_login()

    assert :ok =
             Provider.run(
               ["--provider", "anthropic", "--logout", "--config-path", config_path],
               io()
             )

    assert {:error, _} = Secrets.get("llm_anthropic_api_key")
    content = File.read!(config_path)
    assert content =~ "# keep this comment"
    assert content =~ ~s(provider = "anthropic")
    refute content =~ "auth_source"
    refute content =~ "oauth_secret"
    assert collected_output() =~ "Deleted the stored Anthropic login"

    assert :ok = Provider.run(["anthropic", "--status", "--config-path", config_path], io())
    output = collected_output()
    assert output =~ "Auth source: not set (API key)"
    assert output =~ "Stored login: none"
    assert output =~ "Credentials usable: no"
  end

  test "--logout leaves a non-OAuth secret in place", %{config_path: config_path} do
    {:ok, _} = Secrets.set("llm_anthropic_api_key", "sk-ant-api03-raw")

    assert :ok = Provider.run(["anthropic", "--logout", "--config-path", config_path], io())

    assert {:ok, "sk-ant-api03-raw"} = Secrets.get("llm_anthropic_api_key")
    assert collected_output() =~ "does not hold an OAuth login"
  end

  test "named status and logout target only that account, not the configured login", %{
    config_path: config_path
  } do
    store_login()
    {:ok, active} = Secrets.get("llm_anthropic_api_key")
    alternate = Jason.decode!(active) |> Map.put("account_email", "work@example.com")
    {:ok, _} = Secrets.set("anthropic_work", Jason.encode!(alternate))
    original_config = File.read!(config_path)
    args = ["anthropic", "--config-path", config_path, "--secret-name", "anthropic_work"]

    assert :ok = Provider.run(args ++ ["--status"], io())
    output = collected_output()
    assert output =~ "work@example.com"
    refute output =~ "user@example.com"
    assert output =~ "Credentials usable: yes"
    refute output =~ "sk-ant-oat01"

    assert :ok = Provider.run(args ++ ["--logout"], io())
    assert {:error, _} = Secrets.get("anthropic_work")
    assert {:ok, ^active} = Secrets.get("llm_anthropic_api_key")
    assert File.read!(config_path) == original_config

    assert :ok = Provider.run(args ++ ["--status"], io())
    output = collected_output()
    assert output =~ "Credentials usable: no"
    refute output =~ "user@example.com"
  end

  test "status and logout require a provider" do
    assert_raise Mix.Error, ~r/needs a provider/, fn -> Provider.run(["--status"], io()) end
  end

  defp store_login do
    now = System.system_time(:millisecond)

    {:ok, _} =
      Secrets.set(
        "llm_anthropic_api_key",
        Jason.encode!(%{
          "type" => "anthropic_oauth",
          "source" => "lemon_oauth",
          "access_token" => "sk-ant-oat01-secret",
          "refresh_token" => "sk-ant-ort01-secret",
          "expires_at_ms" => now + 8 * 3_600_000 - 60_000,
          "account_email" => "user@example.com",
          "organization_name" => "Personal",
          "created_at_ms" => now,
          "updated_at_ms" => now
        })
      )
  end

  defp io do
    pid = self()

    %{
      info: fn message -> send(pid, {:info, message}) end,
      error: fn message -> send(pid, {:error, message}) end,
      prompt: fn _ -> "" end,
      secret: fn _ -> "" end
    }
  end

  defp collected_output(acc \\ []) do
    receive do
      {kind, message} when kind in [:info, :error] -> collected_output([message | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
