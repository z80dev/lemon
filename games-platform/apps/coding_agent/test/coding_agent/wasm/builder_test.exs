defmodule CodingAgent.Wasm.BuilderTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Wasm.Builder
  alias CodingAgent.Wasm.Config

  describe "default_runtime_path/0" do
    test "returns a string ending in lemon-wasm-runtime" do
      path = Builder.default_runtime_path()

      assert is_binary(path)
      assert String.ends_with?(path, "lemon-wasm-runtime") or
               String.ends_with?(path, "lemon-wasm-runtime.exe")
    end
  end

  describe "manifest_path/0" do
    test "returns path ending in Cargo.toml" do
      path = Builder.manifest_path()

      assert is_binary(path)
      assert String.ends_with?(path, "Cargo.toml")
    end
  end

  describe "target_dir/0" do
    test "returns path containing _build/lemon-wasm-runtime" do
      path = Builder.target_dir()

      assert is_binary(path)
      assert String.contains?(path, "_build/lemon-wasm-runtime")
    end
  end

  describe "manual_build_command/0" do
    test "returns string containing cargo build" do
      command = Builder.manual_build_command()

      assert is_binary(command)
      assert String.contains?(command, "cargo build")
    end
  end

  describe "ensure_runtime_binary/1" do
    setup do
      tmp_dir = System.tmp_dir!()
      test_id = System.unique_integer([:positive]) |> to_string()
      test_tmp_dir = Path.join(tmp_dir, "builder_test_#{test_id}")
      File.mkdir_p!(test_tmp_dir)

      on_exit(fn ->
        File.rm_rf(test_tmp_dir)
      end)

      {:ok, test_tmp_dir: test_tmp_dir}
    end

    test "with configured path that exists returns {:ok, path, report}", %{
      test_tmp_dir: test_tmp_dir
    } do
      runtime_path = Path.join(test_tmp_dir, "fake-runtime")
      File.write!(runtime_path, "fake binary")

      config = %Config{runtime_path: runtime_path, auto_build: false}

      assert {:ok, ^runtime_path, report} = Builder.ensure_runtime_binary(config)
      assert report.runtime_path == runtime_path
      assert report.built? == false
    end

    test "with configured path that doesn't exist returns {:error, {:runtime_missing, _}}" do
      missing_path = "/tmp/nonexistent_runtime_#{System.unique_integer([:positive])}"
      config = %Config{runtime_path: missing_path, auto_build: false}

      assert {:error, {:runtime_missing, ^missing_path}} = Builder.ensure_runtime_binary(config)
    end

    test "with nil runtime_path falls back to default path" do
      config = %Config{runtime_path: nil, auto_build: false}
      result = Builder.ensure_runtime_binary(config)

      case result do
        {:ok, path, report} ->
          # Default binary exists on this machine
          assert is_binary(path)
          assert report.built? == false

        {:error, {:runtime_missing, path}} ->
          # Default binary not present
          assert is_binary(path)
      end
    end
  end
end
