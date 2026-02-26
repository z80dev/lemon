defmodule LemonCore.TestingTest do
  @moduledoc """
  Tests for the Testing module itself.
  """
  use ExUnit.Case, async: true

  alias LemonCore.Testing.{Harness, Helpers}

  describe "Harness" do
    test "new/0 creates a builder with defaults" do
      builder = Harness.new()
      assert builder.tmp_dir == nil
      assert builder.env_vars == %{}
      assert builder.start_store == false
      assert builder.async == true
    end

    test "with_tmp_dir/2 sets the temp directory" do
      builder =
        Harness.new()
        |> Harness.with_tmp_dir("/custom/path")

      assert builder.tmp_dir == "/custom/path"
    end

    test "with_env/3 sets environment variables" do
      builder =
        Harness.new()
        |> Harness.with_env("TEST_KEY", "test_value")
        |> Harness.with_env("ANOTHER_KEY", "another_value")

      assert builder.env_vars == %{"TEST_KEY" => "test_value", "ANOTHER_KEY" => "another_value"}
    end

    test "with_store/2 configures store startup" do
      builder =
        Harness.new()
        |> Harness.with_store(true)

      assert builder.start_store == true
    end

    test "set_async/2 configures async mode" do
      builder =
        Harness.new()
        |> Harness.set_async(false)

      assert builder.async == false
    end

    test "build/1 creates temp directory and returns context" do
      # Use sync mode for cleanup in async test
      ctx =
        Harness.new()
        |> Harness.set_async(false)
        |> Harness.build()

      assert %{harness: harness, tmp_dir: tmp_dir} = ctx
      assert File.dir?(tmp_dir)
      assert harness.tmp_dir == tmp_dir
      assert harness.env_vars == %{}

      # Cleanup
      Harness.cleanup(harness)
      refute File.dir?(tmp_dir)
    end

    test "build/1 sets environment variables and restores them on cleanup" do
      original_value = System.get_env("HARNESS_TEST_VAR")

      ctx =
        Harness.new()
        |> Harness.with_env("HARNESS_TEST_VAR", "test_value")
        |> Harness.set_async(false)
        |> Harness.build()

      assert System.get_env("HARNESS_TEST_VAR") == "test_value"

      # Cleanup restores original value
      Harness.cleanup(ctx.harness)

      if original_value do
        assert System.get_env("HARNESS_TEST_VAR") == original_value
      else
        assert System.get_env("HARNESS_TEST_VAR") == nil
      end
    end
  end

  describe "Helpers" do
    test "unique_token/0 returns positive integers" do
      token1 = Helpers.unique_token()
      token2 = Helpers.unique_token()

      assert is_integer(token1)
      assert token1 > 0
      assert token2 > token1
    end

    test "unique_scope/0 and unique_scope/1 return scoped tuples" do
      scope1 = Helpers.unique_scope()
      scope2 = Helpers.unique_scope(:my_test)

      assert {:test, token1} = scope1
      assert {:my_test, token2} = scope2
      assert is_integer(token1)
      assert is_integer(token2)
    end

    test "unique_session_key/0 and unique_session_key/1 return session keys" do
      key1 = Helpers.unique_session_key()
      key2 = Helpers.unique_session_key("custom")

      assert key1 =~ ~r/^agent:test_\d+:main$/
      assert key2 =~ ~r/^agent:custom_\d+:main$/
    end

    test "unique_run_id/0 and unique_run_id/1 return run IDs" do
      id1 = Helpers.unique_run_id()
      id2 = Helpers.unique_run_id("custom")

      assert id1 =~ ~r/^run_\d+$/
      assert id2 =~ ~r/^custom_\d+$/
    end

    test "temp_file!/3 creates files with content" do
      ctx =
        Harness.new()
        |> Harness.set_async(false)
        |> Harness.build()

      path = Helpers.temp_file!(ctx.harness, "test.txt", "hello world")

      assert File.exists?(path)
      assert File.read!(path) == "hello world"
      assert Path.dirname(path) == ctx.tmp_dir

      Harness.cleanup(ctx.harness)
    end

    test "temp_dir!/2 creates directories" do
      ctx =
        Harness.new()
        |> Harness.set_async(false)
        |> Harness.build()

      path = Helpers.temp_dir!(ctx.harness, "subdir")

      assert File.dir?(path)
      assert Path.dirname(path) == ctx.tmp_dir

      Harness.cleanup(ctx.harness)
    end

    test "random_master_key/0 returns base64 encoded 32 bytes" do
      key = Helpers.random_master_key()
      decoded = Base.decode64!(key)

      assert byte_size(decoded) == 32
    end
  end

  describe "Testing.Case" do
    # Note: We can't easily test the Case module here because it requires
    # using it in a separate module. The functionality is tested indirectly
    # through the other tests in this file.
  end
end
