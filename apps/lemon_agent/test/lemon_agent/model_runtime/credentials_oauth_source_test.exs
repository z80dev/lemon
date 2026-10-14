defmodule LemonAgent.ModelRuntime.CredentialsOAuthSourceTest do
  # Mutates HOME, process env and the shared secrets table.
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.Credentials
  alias LemonCore.Secrets

  @env ~w(HOME LEMON_SECRETS_MASTER_KEY KIMI_API_KEY MOONSHOT_API_KEY)

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "credentials_oauth_source_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, "home"))
    previous = Map.new(@env, &{&1, System.get_env(&1)})

    System.put_env("HOME", Path.join(tmp_dir, "home"))
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    clear_secrets_table()

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      clear_secrets_table()
      File.rm_rf!(tmp_dir)
    end)

    {:ok, _} =
      Secrets.set(
        "llm_kimi_coding_api_key",
        Jason.encode!(%{
          "type" => "kimi_code_oauth",
          "access_token" => "kimi-login-token",
          "refresh_token" => "kimi-rt",
          "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
        })
      )

    System.put_env("KIMI_API_KEY", "sk-kimi-ambient")
    :ok
  end

  test "auth_source = oauth resolves the stored login ahead of env and plain api_key" do
    providers = %{
      "kimi_coding" => %{
        "auth_source" => "oauth",
        "api_key" => "sk-kimi-plain",
        "api_key_secret" => "llm_kimi_coding_api_key"
      }
    }

    assert Credentials.resolve_provider_api_key("kimi_coding", providers) == "kimi-login-token"
  end

  test "without auth_source the API-key env var still wins" do
    providers = %{"kimi_coding" => %{"api_key_secret" => "llm_kimi_coding_api_key"}}
    assert Credentials.resolve_provider_api_key("kimi_coding", providers) == "sk-kimi-ambient"

    providers = put_in(providers, ["kimi_coding", "auth_source"], "api_key")
    assert Credentials.resolve_provider_api_key("kimi_coding", providers) == "sk-kimi-ambient"
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
