defmodule LemonAiRuntime.StreamOptionsTest do
  use ExUnit.Case, async: false

  alias Ai.Types.{Model, ModelCost}
  alias LemonCore.Secrets

  @env_keys ~w(
    LEMON_GEMINI_PROJECT_ID
    GOOGLE_CLOUD_PROJECT
    GOOGLE_CLOUD_PROJECT_ID
    GCLOUD_PROJECT
    GOOGLE_CLOUD_LOCATION
    GOOGLE_APPLICATION_CREDENTIALS
    AZURE_OPENAI_API_KEY
    AZURE_OPENAI_API_VERSION
    AZURE_OPENAI_BASE_URL
    AZURE_OPENAI_RESOURCE_NAME
    AWS_REGION
    AWS_DEFAULT_REGION
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN
    AWS_PROFILE
    HOME
  )

  setup do
    clear_secrets_table()

    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)

    saved_env = Map.new(@env_keys, fn key -> {key, System.get_env(key)} end)
    Enum.each(@env_keys, &System.delete_env/1)

    tmp_home =
      Path.join(System.tmp_dir!(), "lemon_ai_runtime_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_home)
    System.put_env("HOME", tmp_home)

    on_exit(fn ->
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(tmp_home)
    end)

    %{cwd: tmp_home}
  end

  test "default build initializes maps and provider_options", %{cwd: cwd} do
    opts =
      LemonAiRuntime.build_stream_options(mock_model(:openai, :openai_completions), %{}, nil, cwd)

    assert opts.cwd == cwd
    assert opts.headers == %{}
    assert opts.thinking_budgets == %{}
    assert opts.provider_options == %{}
  end

  test "google vertex stream options resolve project, location, service account, and provider_options",
       %{cwd: cwd} do
    assert {:ok, _} = Secrets.set("vertex_project", "project-from-secret")
    assert {:ok, _} = Secrets.set("vertex_location", "us-central1")
    assert {:ok, _} = Secrets.set("vertex_sa", "{\"client_email\":\"svc@example.com\"}")

    providers = %{
      "google_vertex" => %{
        project_secret: "vertex_project",
        location_secret: "vertex_location",
        service_account_json_secret: "vertex_sa"
      }
    }

    opts =
      LemonAiRuntime.build_stream_options(
        mock_model(:google_vertex, :google_vertex),
        providers,
        nil,
        cwd
      )

    assert opts.project == "project-from-secret"
    assert opts.location == "us-central1"
    assert opts.service_account_json == "{\"client_email\":\"svc@example.com\"}"
    assert opts.provider_options.google_vertex.project == "project-from-secret"
    assert opts.provider_options.google_vertex.location == "us-central1"
  end

  test "google gemini cli project precedence prefers explicit opts over config and env", %{
    cwd: cwd
  } do
    assert {:ok, _} = Secrets.set("gemini_project", "project-from-secret")
    System.put_env("LEMON_GEMINI_PROJECT_ID", "env-project")
    System.put_env("GOOGLE_CLOUD_PROJECT", "cloud-project")

    providers = %{
      "google_gemini_cli" => %{
        project_id: "provider-project",
        project_secret: "gemini_project"
      }
    }

    opts =
      LemonAiRuntime.build_stream_options(
        mock_model(:google_gemini_cli, :google_gemini_cli),
        providers,
        %{project: "opts-project", project_id: "opts-project-id"},
        cwd
      )

    assert opts.project == "opts-project"

    opts =
      LemonAiRuntime.build_stream_options(
        mock_model(:google_gemini_cli, :google_gemini_cli),
        providers,
        %{},
        cwd
      )

    assert opts.project == "provider-project"

    opts =
      LemonAiRuntime.build_stream_options(
        mock_model(:google_gemini_cli, :google_gemini_cli),
        %{"google_gemini_cli" => %{project_secret: "gemini_project"}},
        %{},
        cwd
      )

    assert opts.project == "project-from-secret"

    opts =
      LemonAiRuntime.build_stream_options(
        mock_model(:google_gemini_cli, :google_gemini_cli),
        %{},
        %{},
        cwd
      )

    assert opts.project == "env-project"
  end

  test "azure stream options resolve api key, legacy thinking_budgets, and provider_options", %{
    cwd: cwd
  } do
    assert {:ok, _} = Secrets.set("azure_api_key", "azure-key-from-secret")

    providers = %{
      "azure_openai_responses" => %{
        api_key_secret: "azure_api_key",
        base_url: "https://example.openai.azure.com",
        api_version: "2024-12-01-preview",
        resource_name: "azure-resource",
        deployment_name_map: %{"gpt-5" => "gpt-5-deployment"}
      }
    }

    opts =
      LemonAiRuntime.build_stream_options(
        mock_model(:openai, :azure_openai_responses),
        providers,
        %{},
        cwd
      )

    assert opts.api_key == "azure-key-from-secret"
    assert opts.thinking_budgets.azure_base_url == "https://example.openai.azure.com"
    assert opts.thinking_budgets.azure_api_version == "2024-12-01-preview"
    assert opts.thinking_budgets.azure_resource_name == "azure-resource"
    assert opts.thinking_budgets.azure_deployment_name_map == %{"gpt-5" => "gpt-5-deployment"}

    assert opts.provider_options.azure_openai_responses.base_url ==
             "https://example.openai.azure.com"

    assert opts.provider_options.azure_openai_responses.api_version == "2024-12-01-preview"
  end

  test "bedrock stream options resolve headers and keep legacy header compatibility", %{cwd: cwd} do
    assert {:ok, _} = Secrets.set("aws_access", "access-key")
    assert {:ok, _} = Secrets.set("aws_secret", "secret-key")
    assert {:ok, _} = Secrets.set("aws_session", "session-token")

    providers = %{
      "amazon_bedrock" => %{
        region: "us-west-2",
        access_key_id_secret: "aws_access",
        secret_access_key_secret: "aws_secret",
        session_token_secret: "aws_session"
      }
    }

    opts =
      LemonAiRuntime.build_stream_options(
        mock_model(:amazon_bedrock, :bedrock_converse_stream),
        providers,
        %{},
        cwd
      )

    assert opts.headers["aws_region"] == "us-west-2"
    assert opts.headers["aws_access_key_id"] == "access-key"
    assert opts.headers["aws_secret_access_key"] == "secret-key"
    assert opts.headers["aws_session_token"] == "session-token"
    assert opts.provider_options.bedrock_converse_stream.aws_region == "us-west-2"
  end

  defp mock_model(provider, api) do
    %Model{
      id: "#{provider}-model",
      name: "#{provider}-model",
      provider: provider,
      api: api,
      base_url: "",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 0,
      max_tokens: 0,
      headers: %{}
    }
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
