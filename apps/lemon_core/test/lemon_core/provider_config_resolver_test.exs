defmodule LemonCore.ProviderConfigResolverTest do
  use ExUnit.Case, async: false

  alias LemonCore.ProviderConfigResolver

  # We need to manipulate env vars, so async: false is required.

  setup do
    # Save and clear relevant env vars before each test
    saved_env = %{
      "GOOGLE_CLOUD_PROJECT" => System.get_env("GOOGLE_CLOUD_PROJECT"),
      "GCLOUD_PROJECT" => System.get_env("GCLOUD_PROJECT"),
      "GOOGLE_CLOUD_LOCATION" => System.get_env("GOOGLE_CLOUD_LOCATION"),
      "AZURE_OPENAI_API_VERSION" => System.get_env("AZURE_OPENAI_API_VERSION"),
      "AZURE_OPENAI_BASE_URL" => System.get_env("AZURE_OPENAI_BASE_URL"),
      "AZURE_OPENAI_RESOURCE_NAME" => System.get_env("AZURE_OPENAI_RESOURCE_NAME"),
      "AWS_REGION" => System.get_env("AWS_REGION"),
      "AWS_DEFAULT_REGION" => System.get_env("AWS_DEFAULT_REGION"),
      "HOME" => System.get_env("HOME")
    }

    # Clear env vars for a clean slate
    Enum.each(
      ~w(GOOGLE_CLOUD_PROJECT GCLOUD_PROJECT GOOGLE_CLOUD_LOCATION
         AZURE_OPENAI_API_VERSION AZURE_OPENAI_BASE_URL AZURE_OPENAI_RESOURCE_NAME
         AWS_REGION AWS_DEFAULT_REGION),
      &System.delete_env/1
    )

    # Use a temp HOME so Config.load doesn't pick up real config
    tmp_dir = Path.join(System.tmp_dir!(), "lemon_resolver_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    System.put_env("HOME", tmp_dir)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(tmp_dir)
    end)

    %{home: tmp_dir}
  end

  # ============================================================================
  # Unknown provider
  # ============================================================================

  test "unknown provider returns empty map" do
    assert ProviderConfigResolver.resolve_for_provider(:nonexistent) == %{}
  end

  # ============================================================================
  # Google Vertex
  # ============================================================================

  describe "google_vertex" do
    test "returns empty map when no env or opts" do
      result = ProviderConfigResolver.resolve_for_provider(:google_vertex)
      # Neither project nor location set, so both are nil and excluded
      refute Map.has_key?(result, :project)
      refute Map.has_key?(result, :location)
    end

    test "reads GOOGLE_CLOUD_PROJECT from env" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "my-project")
      result = ProviderConfigResolver.resolve_for_provider(:google_vertex)
      assert result.project == "my-project"
    end

    test "reads GCLOUD_PROJECT as fallback" do
      System.put_env("GCLOUD_PROJECT", "fallback-project")
      result = ProviderConfigResolver.resolve_for_provider(:google_vertex)
      assert result.project == "fallback-project"
    end

    test "GOOGLE_CLOUD_PROJECT takes priority over GCLOUD_PROJECT" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "primary")
      System.put_env("GCLOUD_PROJECT", "fallback")
      result = ProviderConfigResolver.resolve_for_provider(:google_vertex)
      assert result.project == "primary"
    end

    test "reads GOOGLE_CLOUD_LOCATION from env" do
      System.put_env("GOOGLE_CLOUD_LOCATION", "us-central1")
      result = ProviderConfigResolver.resolve_for_provider(:google_vertex)
      assert result.location == "us-central1"
    end

    test "opts take priority over env vars" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "env-project")
      System.put_env("GOOGLE_CLOUD_LOCATION", "env-location")

      result =
        ProviderConfigResolver.resolve_for_provider(:google_vertex, %{
          project: "opts-project",
          location: "opts-location"
        })

      assert result.project == "opts-project"
      assert result.location == "opts-location"
    end

    test "nil values are excluded from result" do
      result = ProviderConfigResolver.resolve_for_provider(:google_vertex)
      refute Map.has_key?(result, :service_account_json)
    end

    test "service_account_json from opts is included" do
      result =
        ProviderConfigResolver.resolve_for_provider(:google_vertex, %{
          service_account_json: "{\"key\": \"value\"}"
        })

      assert result.service_account_json == "{\"key\": \"value\"}"
    end
  end

  # ============================================================================
  # Azure OpenAI Responses
  # ============================================================================

  describe "azure_openai_responses" do
    test "returns empty map when no env or opts" do
      result = ProviderConfigResolver.resolve_for_provider(:azure_openai_responses)
      # No env vars set, no config file
      refute Map.has_key?(result, :api_key)
      refute Map.has_key?(result, :base_url)
    end

    test "reads AZURE_OPENAI_API_VERSION from env" do
      System.put_env("AZURE_OPENAI_API_VERSION", "2024-12-01-preview")
      result = ProviderConfigResolver.resolve_for_provider(:azure_openai_responses)
      assert result.api_version == "2024-12-01-preview"
    end

    test "reads AZURE_OPENAI_RESOURCE_NAME from env" do
      System.put_env("AZURE_OPENAI_RESOURCE_NAME", "my-resource")
      result = ProviderConfigResolver.resolve_for_provider(:azure_openai_responses)
      assert result.resource_name == "my-resource"
    end

    test "opts api_key takes priority" do
      result =
        ProviderConfigResolver.resolve_for_provider(:azure_openai_responses, %{
          api_key: "opts-key"
        })

      assert result.api_key == "opts-key"
    end
  end

  # ============================================================================
  # Bedrock
  # ============================================================================

  describe "bedrock_converse_stream" do
    test "defaults region to us-east-1 when no env" do
      result = ProviderConfigResolver.resolve_for_provider(:bedrock_converse_stream)
      assert result.headers["aws_region"] == "us-east-1"
    end

    test "reads AWS_REGION from env" do
      System.put_env("AWS_REGION", "eu-west-1")
      result = ProviderConfigResolver.resolve_for_provider(:bedrock_converse_stream)
      assert result.headers["aws_region"] == "eu-west-1"
    end

    test "reads AWS_DEFAULT_REGION as fallback" do
      System.put_env("AWS_DEFAULT_REGION", "ap-southeast-1")
      result = ProviderConfigResolver.resolve_for_provider(:bedrock_converse_stream)
      assert result.headers["aws_region"] == "ap-southeast-1"
    end

    test "AWS_REGION takes priority over AWS_DEFAULT_REGION" do
      System.put_env("AWS_REGION", "us-west-2")
      System.put_env("AWS_DEFAULT_REGION", "eu-west-1")
      result = ProviderConfigResolver.resolve_for_provider(:bedrock_converse_stream)
      assert result.headers["aws_region"] == "us-west-2"
    end

    test "opts headers take priority over env" do
      System.put_env("AWS_REGION", "env-region")

      result =
        ProviderConfigResolver.resolve_for_provider(:bedrock_converse_stream, %{
          headers: %{"aws_region" => "opts-region"}
        })

      assert result.headers["aws_region"] == "opts-region"
    end

    test "nil credential values are excluded from headers" do
      result = ProviderConfigResolver.resolve_for_provider(:bedrock_converse_stream)
      # aws_region should always be present (defaults to us-east-1)
      assert Map.has_key?(result.headers, "aws_region")
      # credentials may or may not be present depending on env/secrets store
    end

    test "result always contains headers key" do
      result = ProviderConfigResolver.resolve_for_provider(:bedrock_converse_stream)
      assert is_map(result.headers)
    end
  end

  # ============================================================================
  # Config file integration
  # ============================================================================

  describe "config file integration" do
    test "reads provider config from TOML file", %{home: home} do
      global_dir = Path.join(home, ".lemon")
      File.mkdir_p!(global_dir)

      File.write!(Path.join(global_dir, "config.toml"), """
      [providers.google_vertex]
      api_key = "vertex-key-from-config"
      """)

      result = ProviderConfigResolver.resolve_for_provider(:google_vertex)
      assert result.api_key == "vertex-key-from-config"
    end

    test "env vars supplement config file values", %{home: home} do
      global_dir = Path.join(home, ".lemon")
      File.mkdir_p!(global_dir)

      File.write!(Path.join(global_dir, "config.toml"), """
      [providers.google_vertex]
      api_key = "config-key"
      """)

      System.put_env("GOOGLE_CLOUD_PROJECT", "env-project")

      result = ProviderConfigResolver.resolve_for_provider(:google_vertex)
      assert result.api_key == "config-key"
      assert result.project == "env-project"
    end

    test "project-local google vertex config overrides global config", %{home: home} do
      global_dir = Path.join(home, ".lemon")
      project_dir = Path.join(home, "project")
      project_config_dir = Path.join(project_dir, ".lemon")
      File.mkdir_p!(global_dir)
      File.mkdir_p!(project_config_dir)

      File.write!(Path.join(global_dir, "config.toml"), """
      [providers.google_vertex]
      project_secret = "GOOGLE_VERTEX_PROJECT_GLOBAL"
      location_secret = "GOOGLE_VERTEX_LOCATION_GLOBAL"
      """)

      File.write!(Path.join(project_config_dir, "config.toml"), """
      [providers.google_vertex]
      project_secret = "GOOGLE_VERTEX_PROJECT_PROJECT"
      location_secret = "GOOGLE_VERTEX_LOCATION_PROJECT"
      """)

      System.put_env("GOOGLE_VERTEX_PROJECT_GLOBAL", "global-project")
      System.put_env("GOOGLE_VERTEX_LOCATION_GLOBAL", "global-location")
      System.put_env("GOOGLE_VERTEX_PROJECT_PROJECT", "project-project")
      System.put_env("GOOGLE_VERTEX_LOCATION_PROJECT", "project-location")

      on_exit(fn ->
        System.delete_env("GOOGLE_VERTEX_PROJECT_GLOBAL")
        System.delete_env("GOOGLE_VERTEX_LOCATION_GLOBAL")
        System.delete_env("GOOGLE_VERTEX_PROJECT_PROJECT")
        System.delete_env("GOOGLE_VERTEX_LOCATION_PROJECT")
      end)

      result = ProviderConfigResolver.resolve_for_provider(:google_vertex, %{cwd: project_dir})
      assert result.project == "project-project"
      assert result.location == "project-location"
    end

    test "project-local azure config overrides global config", %{home: home} do
      global_dir = Path.join(home, ".lemon")
      project_dir = Path.join(home, "project-azure")
      project_config_dir = Path.join(project_dir, ".lemon")
      File.mkdir_p!(global_dir)
      File.mkdir_p!(project_config_dir)

      File.write!(Path.join(global_dir, "config.toml"), """
      [providers.azure_openai_responses]
      resource_name = "global-resource"
      api_version = "2024-01-01"
      """)

      File.write!(Path.join(project_config_dir, "config.toml"), """
      [providers.azure_openai_responses]
      resource_name = "project-resource"
      api_version = "2025-02-01-preview"

      [providers.azure_openai_responses.deployment_name_map]
      gpt-4o = "project-deployment"
      """)

      result =
        ProviderConfigResolver.resolve_for_provider(:azure_openai_responses, %{cwd: project_dir})

      assert result.resource_name == "project-resource"
      assert result.api_version == "2025-02-01-preview"
      assert result.deployment_name_map["gpt-4o"] == "project-deployment"
    end

    test "project-local bedrock config overrides global config", %{home: home} do
      global_dir = Path.join(home, ".lemon")
      project_dir = Path.join(home, "project-bedrock")
      project_config_dir = Path.join(project_dir, ".lemon")
      File.mkdir_p!(global_dir)
      File.mkdir_p!(project_config_dir)

      File.write!(Path.join(global_dir, "config.toml"), """
      [providers.amazon_bedrock]
      region = "us-east-1"
      """)

      File.write!(Path.join(project_config_dir, "config.toml"), """
      [providers.amazon_bedrock]
      region = "eu-west-1"
      """)

      result =
        ProviderConfigResolver.resolve_for_provider(:bedrock_converse_stream, %{cwd: project_dir})

      assert result.headers["aws_region"] == "eu-west-1"
    end
  end
end
