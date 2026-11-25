defmodule LemonAgent.ModelRuntime.CredentialsSecretSourcesTest do
  @moduledoc """
  Model credentials resolve `secret:` refs through configured external secret
  sources and never substitute an ambient environment value when the store or
  a source fails.
  """
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.Credentials
  alias LemonCore.Secrets
  alias LemonCore.Store

  @env_keys ~w(ANTHROPIC_API_KEY ANTHROPIC_TOKEN CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY
               POOL_EXT_KEY ANTHROPIC_EXT_SECRET ENV_TRIPWIRE_SECRET AWS_ACCESS_KEY_ID
               GOOGLE_APPLICATION_CREDENTIALS_JSON AZURE_OPENAI_API_KEY)

  @tripwire "ambient-must-not-win"

  setup do
    clear_secrets_table()

    tmp_dir =
      Path.join(System.tmp_dir!(), "credentials_sources_#{System.unique_integer([:positive])}")

    home_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(Path.join(home_dir, ".lemon"))

    original_home = System.get_env("HOME")
    original_paths = Application.get_env(:lemon_core, :paths)
    Application.delete_env(:lemon_core, :paths)
    System.put_env("HOME", home_dir)
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    Enum.each(@env_keys, &System.delete_env/1)
    LemonCore.Secrets.SourceCache.clear()

    on_exit(fn ->
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_paths,
        do: Application.put_env(:lemon_core, :paths, original_paths),
        else: Application.delete_env(:lemon_core, :paths)

      Enum.each(@env_keys, &System.delete_env/1)
      LemonCore.Secrets.SourceCache.clear()
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, home_dir: home_dir}
  end

  test "a pool secret: ref and an Anthropic api_key_secret resolve from an external source",
       ctx do
    configure_source(ctx, "success")

    config = %{
      providers: %{"openai" => %{}},
      provider_routing: %{
        default_pool: "burst",
        credential_pools: %{
          "burst" => %{
            providers: ["openai"],
            strategy: "priority",
            credentials: %{"openai" => [%{source: :secret, name: "POOL_EXT_KEY"}]}
          }
        }
      }
    }

    assert [%{ref: "secret:POOL_EXT_KEY", api_key: "pool-from-source"} | _] =
             Credentials.list_provider_api_keys(config, :openai)

    providers = %{"anthropic" => %{api_key_secret: "ANTHROPIC_EXT_SECRET"}}

    assert Credentials.resolve_provider_api_key(:anthropic, providers) ==
             "sk-ant-api03-from-source"
  end

  test "a failing external source yields no credential even with an env tripwire", ctx do
    configure_source(ctx, "failure")
    System.put_env("ENV_TRIPWIRE_SECRET", "ambient-must-not-win")

    assert Credentials.resolve_secret_api_key("ENV_TRIPWIRE_SECRET") == nil
    assert Credentials.resolve_secret_api_key("ENV_TRIPWIRE_SECRET", env_fallback: false) == nil
  end

  test "an unreadable store record yields no credential even with an env tripwire" do
    System.put_env("ENV_TRIPWIRE_SECRET", "ambient-must-not-win")
    :ok = Store.put(Secrets.table(), {"default", "ENV_TRIPWIRE_SECRET"}, "corrupt-record")

    assert Credentials.resolve_secret_api_key("ENV_TRIPWIRE_SECRET") == nil

    providers = %{"openai" => %{api_key_secret: "ENV_TRIPWIRE_SECRET"}}
    assert Credentials.resolve_provider_api_key(:openai, providers) in [nil, ""]
  end

  test "an unreadable default Anthropic login never reaches ambient Claude tokens" do
    # Shaped like a Claude OAuth token so the ambient reader would accept it.
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-ambient-must-not-win")
    System.put_env("ANTHROPIC_TOKEN", "sk-ant-oat01-ambient-must-not-win")
    corrupt(LemonAgent.ModelRuntime.ProviderNames.oauth_default_secret_name("anthropic"))

    providers = %{"anthropic" => %{auth_source: "oauth"}}
    assert Credentials.resolve_provider_api_key(:anthropic, providers) == ""
  end

  test "an unreadable configured api_key_secret never yields another alias or the default" do
    assert {:ok, _} = Secrets.set("llm_openai_api_key", @tripwire)
    corrupt("CONFIGURED_OPENAI_SECRET")
    providers = %{"openai" => %{api_key_secret: "CONFIGURED_OPENAI_SECRET"}}
    assert Credentials.resolve_provider_api_key(:openai, providers) in [nil, ""]

    corrupt("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_TOKEN", @tripwire)
    providers = %{"anthropic" => %{auth_source: "api_key"}}
    assert Credentials.resolve_provider_api_key(:anthropic, providers) == ""
  end

  test "provider config resolver stops at unreadable Google, AWS and Azure secrets" do
    alias LemonAgent.ModelRuntime.StreamOptions.ProviderSettings

    for name <- ~w(VERTEX_SA_SECRET AWS_KEY_SECRET AZURE_KEY_SECRET), do: corrupt(name)
    System.put_env("GOOGLE_APPLICATION_CREDENTIALS_JSON", @tripwire)
    System.put_env("AWS_ACCESS_KEY_ID", @tripwire)
    System.put_env("AZURE_OPENAI_API_KEY", @tripwire)

    vertex =
      ProviderSettings.resolve(:google_vertex, %{
        provider_config: %{service_account_json_secret: "VERTEX_SA_SECRET"}
      })

    refute Map.has_key?(vertex, :service_account_json)

    bedrock =
      ProviderSettings.resolve(:bedrock_converse_stream, %{
        provider_config: %{access_key_id_secret: "AWS_KEY_SECRET"}
      })

    refute Map.has_key?(bedrock.headers, "aws_access_key_id")

    azure =
      ProviderSettings.resolve(:azure_openai_responses, %{
        provider_config: %{api_key_secret: "AZURE_KEY_SECRET"}
      })

    refute Map.has_key?(azure, :api_key)
  end

  defp corrupt(name) do
    :ok = Store.put(Secrets.table(), {"default", name}, "corrupt-record")
  end

  defp configure_source(ctx, mode) do
    stub = Path.join(ctx.tmp_dir, "source-stub")

    File.write!(stub, """
    #!/bin/sh
    case "$1" in
      success)
        printf 'POOL_EXT_KEY=pool-from-source\\n'
        printf 'ANTHROPIC_EXT_SECRET=sk-ant-api03-from-source\\n'
        ;;
      *) exit 9 ;;
    esac
    """)

    File.chmod!(stub, 0o700)

    File.write!(Path.join([ctx.home_dir, ".lemon", "config.toml"]), """
    [secrets.sources.stub]
    type = "command"
    enabled = true
    argv = ["#{stub}", "#{mode}"]
    """)
  end

  defp clear_secrets_table do
    Secrets.table()
    |> Store.list()
    |> Enum.each(fn {key, _} -> Store.delete(Secrets.table(), key) end)
  end
end
