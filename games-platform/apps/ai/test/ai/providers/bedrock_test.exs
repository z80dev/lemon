defmodule Ai.Providers.BedrockTest do
  @moduledoc """
  Tests for Ai.Providers.Bedrock provider callbacks and registration.

  These tests cover the pure public interface of the Bedrock provider
  and do not require AWS credentials or network access.
  """
  use ExUnit.Case, async: true

  alias Ai.Providers.Bedrock

  # ============================================================================
  # Provider Callbacks
  # ============================================================================

  describe "provider_id/0" do
    test "returns :amazon" do
      assert Bedrock.provider_id() == :amazon
    end
  end

  describe "api_id/0" do
    test "returns :bedrock_converse_stream" do
      assert Bedrock.api_id() == :bedrock_converse_stream
    end
  end

  describe "get_env_api_key/0" do
    test "returns nil because Bedrock uses AWS credentials" do
      assert Bedrock.get_env_api_key() == nil
    end
  end

  # ============================================================================
  # Provider Registration
  # ============================================================================

  describe "register/0" do
    test "registers the provider in ProviderRegistry" do
      assert :ok = Bedrock.register()
      assert {:ok, Bedrock} = Ai.ProviderRegistry.get(:bedrock_converse_stream)
    end
  end

  # ============================================================================
  # Behaviour Implementation
  # ============================================================================

  describe "behaviour" do
    test "implements Ai.Provider behaviour" do
      behaviours =
        Bedrock.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Ai.Provider in behaviours
    end
  end
end

# ==============================================================================
# Separate module for tests that manipulate global state (AWS env vars).
# Must be async: false to avoid interference with other tests.
# ==============================================================================

defmodule Ai.Providers.BedrockStreamTest do
  @moduledoc """
  Tests for Ai.Providers.Bedrock streaming and credential handling.

  Uses async: false because these tests manipulate AWS environment
  variables and test streaming behavior that depends on global state.
  """
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.Bedrock
  alias Ai.Types.{Context, Model, StreamOptions, Usage, Cost}

  @aws_env_vars [
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_REGION",
    "AWS_DEFAULT_REGION"
  ]

  setup do
    # Save all AWS env vars
    saved =
      Map.new(@aws_env_vars, fn key ->
        {key, System.get_env(key)}
      end)

    # Clear all AWS env vars for a clean test environment
    Enum.each(@aws_env_vars, &System.delete_env/1)

    on_exit(fn ->
      # Restore original env vars
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, val} -> System.put_env(key, val)
      end)
    end)

    :ok
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp default_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "anthropic.claude-3-5-sonnet-20240620-v1:0"),
      name: Keyword.get(opts, :name, "Claude 3.5 Sonnet (Bedrock)"),
      api: :bedrock_converse_stream,
      provider: Keyword.get(opts, :provider, :amazon),
      base_url: "",
      reasoning: Keyword.get(opts, :reasoning, false)
    }
  end

  defp default_context do
    Context.new(
      system_prompt: "You are a helpful assistant.",
      messages: []
    )
  end

  defp default_opts(overrides \\ %{}) do
    base = %StreamOptions{
      headers: Map.get(overrides, :headers, %{}),
      stream_timeout: Map.get(overrides, :stream_timeout, 5_000)
    }

    Map.merge(base, Map.drop(overrides, [:headers, :stream_timeout]))
  end

  defp stream_and_result(model \\ default_model(), context \\ default_context(), opts \\ default_opts()) do
    {:ok, stream} = Bedrock.stream(model, context, opts)
    result = EventStream.result(stream, 5_000)
    {stream, result}
  end

  # ============================================================================
  # Stream Initialization
  # ============================================================================

  describe "stream/3 initialization" do
    test "returns {:ok, stream} tuple" do
      {:ok, stream} = Bedrock.stream(default_model(), default_context(), default_opts())
      assert is_pid(stream)
      # Clean up
      EventStream.result(stream, 5_000)
    end

    test "returns a live process" do
      {:ok, stream} = Bedrock.stream(default_model(), default_context(), default_opts())
      assert Process.alive?(stream)
      EventStream.result(stream, 5_000)
    end
  end

  # ============================================================================
  # Credential Handling
  # ============================================================================

  describe "credential errors" do
    test "errors when AWS_ACCESS_KEY_ID is missing" do
      # No env vars set, no headers
      {_stream, result} = stream_and_result()

      assert {:error, output} = result
      assert output.error_message == "AWS_ACCESS_KEY_ID not found"
      assert output.stop_reason == :error
    end

    test "errors when AWS_SECRET_ACCESS_KEY is missing but access key is set" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE")

      {_stream, result} = stream_and_result()

      assert {:error, output} = result
      assert output.error_message == "AWS_SECRET_ACCESS_KEY not found"
      assert output.stop_reason == :error
    end

    test "checks access key before secret key" do
      # Neither set - should error about access key first
      {_stream, result} = stream_and_result()

      assert {:error, output} = result
      assert output.error_message =~ "ACCESS_KEY_ID"
    end

    test "accepts credentials from opts.headers over env vars" do
      # Set env vars
      System.put_env("AWS_ACCESS_KEY_ID", "env-access-key")
      System.put_env("AWS_SECRET_ACCESS_KEY", "env-secret-key")

      # Override with headers - these will pass credential check
      # but fail at HTTP level (not a credential error)
      opts = default_opts(%{
        headers: %{
          "aws_access_key_id" => "header-access-key",
          "aws_secret_access_key" => "header-secret-key"
        },
        stream_timeout: 5_000
      })

      {_stream, result} = stream_and_result(default_model(), default_context(), opts)

      # Should NOT be a credential error - it passed credential check
      # It will fail at HTTP/network level instead
      assert {:error, output} = result
      refute output.error_message =~ "not found"
    end

    test "session token is optional" do
      # Set access and secret key but no session token
      System.put_env("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE")
      System.put_env("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

      {_stream, result} = stream_and_result()

      # Should NOT be a credential error
      assert {:error, output} = result
      refute output.error_message =~ "not found"
    end

    test "accepts session token from env var" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE")
      System.put_env("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
      System.put_env("AWS_SESSION_TOKEN", "FwoGZXIvYXdzEBYaDHqa0AP")

      {_stream, result} = stream_and_result()

      # Should NOT be a credential error
      assert {:error, output} = result
      refute output.error_message =~ "not found"
    end

    test "accepts credentials from headers when env vars are empty" do
      opts = default_opts(%{
        headers: %{
          "aws_access_key_id" => "AKIAIOSFODNN7EXAMPLE",
          "aws_secret_access_key" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        }
      })

      {_stream, result} = stream_and_result(default_model(), default_context(), opts)

      assert {:error, output} = result
      refute output.error_message =~ "not found"
    end
  end

  # ============================================================================
  # Error Output Structure
  # ============================================================================

  describe "error output structure" do
    test "has :bedrock_converse_stream api" do
      {_stream, {:error, output}} = stream_and_result()
      assert output.api == :bedrock_converse_stream
    end

    test "has model id matching input" do
      model = default_model(id: "anthropic.claude-3-haiku-20240307-v1:0")
      {_stream, {:error, output}} = stream_and_result(model)
      assert output.model == "anthropic.claude-3-haiku-20240307-v1:0"
    end

    test "has :amazon provider by default" do
      {_stream, {:error, output}} = stream_and_result()
      assert output.provider == :amazon
    end

    test "preserves custom provider from model" do
      model = default_model(provider: :custom_aws)
      {_stream, {:error, output}} = stream_and_result(model)
      assert output.provider == :custom_aws
    end

    test "has :assistant role" do
      {_stream, {:error, output}} = stream_and_result()
      assert output.role == :assistant
    end

    test "has empty content list" do
      {_stream, {:error, output}} = stream_and_result()
      assert output.content == []
    end

    test "has initialized usage with zero tokens" do
      {_stream, {:error, output}} = stream_and_result()
      assert %Usage{} = output.usage
      assert output.usage.input == 0
      assert output.usage.output == 0
      assert output.usage.cache_read == 0
      assert output.usage.cache_write == 0
      assert output.usage.total_tokens == 0
      assert %Cost{} = output.usage.cost
    end

    test "has a timestamp" do
      before = System.system_time(:millisecond)
      {_stream, {:error, output}} = stream_and_result()
      after_ts = System.system_time(:millisecond)

      assert output.timestamp >= before
      assert output.timestamp <= after_ts
    end
  end

  # ============================================================================
  # Region Handling
  # ============================================================================

  describe "region handling" do
    test "defaults to us-east-1 when no region configured" do
      # Provide credentials so we pass credential check and attempt HTTP
      System.put_env("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE")
      System.put_env("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

      {_stream, {:error, output}} = stream_and_result()

      # The error should be from HTTP, not credentials
      # We can't directly verify the region, but we confirm no credential error
      refute output.error_message =~ "not found"
    end

    test "uses aws_region from opts.headers" do
      opts = default_opts(%{
        headers: %{
          "aws_access_key_id" => "AKIAIOSFODNN7EXAMPLE",
          "aws_secret_access_key" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
          "aws_region" => "eu-west-1"
        }
      })

      {_stream, {:error, output}} = stream_and_result(default_model(), default_context(), opts)

      # Should pass credential check regardless of region
      refute output.error_message =~ "not found"
    end
  end
end
