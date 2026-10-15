defmodule LemonCore.TestingTest do
  @moduledoc """
  Tests for the Testing module itself.
  """
  use ExUnit.Case, async: true

  alias LemonCore.Testing.{Harness, Helpers}

  describe "Harness" do
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
end
