defmodule CodingAgent.Wasm.ConfigTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Wasm.Config

  @default_memory_limit 10 * 1024 * 1024
  @default_timeout_ms 60_000
  @default_fuel_limit 10_000_000
  @default_max_depth 4

  setup do
    tmp_dir = System.tmp_dir!()
    test_id = System.unique_integer([:positive]) |> to_string()
    test_tmp_dir = Path.join(tmp_dir, "config_test_#{test_id}")
    File.mkdir_p!(test_tmp_dir)

    on_exit(fn ->
      File.rm_rf(test_tmp_dir)
    end)

    {:ok, test_tmp_dir: test_tmp_dir}
  end

  describe "load/2" do
    test "returns default config when settings is nil" do
      config = Config.load(".", nil)

      assert config.enabled == false
      assert config.auto_build == true
      assert config.runtime_path == nil
      assert config.tool_paths == []
      assert config.default_memory_limit == @default_memory_limit
      assert config.default_timeout_ms == @default_timeout_ms
      assert config.default_fuel_limit == @default_fuel_limit
      assert config.cache_compiled == true
      assert config.cache_dir == nil
      assert config.max_tool_invoke_depth == @default_max_depth
    end

    test "returns default config when settings is an empty map" do
      config = Config.load(".", %{})

      assert config.enabled == false
      assert config.auto_build == true
      assert config.runtime_path == nil
      assert config.tool_paths == []
      assert config.default_memory_limit == @default_memory_limit
      assert config.default_timeout_ms == @default_timeout_ms
      assert config.default_fuel_limit == @default_fuel_limit
      assert config.cache_compiled == true
      assert config.cache_dir == nil
      assert config.max_tool_invoke_depth == @default_max_depth
    end

    test "parses enabled boolean from various truthy formats" do
      for value <- [true, "true", 1, "1"] do
        config = Config.load(".", %{tools: %{wasm: %{enabled: value}}})
        assert config.enabled == true, "expected enabled to be true for #{inspect(value)}"
      end
    end

    test "parses enabled boolean from various falsy formats" do
      for value <- [false, "false", 0, "0"] do
        config = Config.load(".", %{tools: %{wasm: %{enabled: value}}})
        assert config.enabled == false, "expected enabled to be false for #{inspect(value)}"
      end
    end

    test "default_memory_limit parses positive integers" do
      config = Config.load(".", %{tools: %{wasm: %{default_memory_limit: 20_000_000}}})
      assert config.default_memory_limit == 20_000_000
    end

    test "default_memory_limit parses string integers" do
      config = Config.load(".", %{tools: %{wasm: %{default_memory_limit: "15000000"}}})
      assert config.default_memory_limit == 15_000_000
    end

    test "default_memory_limit enforces minimum of 1" do
      config = Config.load(".", %{tools: %{wasm: %{default_memory_limit: 0}}})
      assert config.default_memory_limit == 1

      config = Config.load(".", %{tools: %{wasm: %{default_memory_limit: -100}}})
      assert config.default_memory_limit == 1
    end

    test "default_timeout_ms parses positive integers" do
      config = Config.load(".", %{tools: %{wasm: %{default_timeout_ms: 120_000}}})
      assert config.default_timeout_ms == 120_000
    end

    test "default_timeout_ms parses string integers" do
      config = Config.load(".", %{tools: %{wasm: %{default_timeout_ms: "90000"}}})
      assert config.default_timeout_ms == 90_000
    end

    test "default_fuel_limit parses positive integers" do
      config = Config.load(".", %{tools: %{wasm: %{default_fuel_limit: 20_000_000}}})
      assert config.default_fuel_limit == 20_000_000
    end

    test "default_fuel_limit parses string integers" do
      config = Config.load(".", %{tools: %{wasm: %{default_fuel_limit: "5000000"}}})
      assert config.default_fuel_limit == 5_000_000
    end

    test "tool_paths parses list of paths", %{test_tmp_dir: test_tmp_dir} do
      tool_dir = Path.join(test_tmp_dir, "wasm-tools")
      File.mkdir_p!(tool_dir)

      config = Config.load(test_tmp_dir, %{tools: %{wasm: %{tool_paths: [tool_dir]}}})

      assert config.tool_paths == [Path.expand(tool_dir, test_tmp_dir)]
      assert Path.expand(tool_dir, test_tmp_dir) in config.discover_paths
    end

    test "tool_paths parses relative paths", %{test_tmp_dir: test_tmp_dir} do
      tool_dir = "wasm-tools"
      File.mkdir_p!(Path.join(test_tmp_dir, tool_dir))

      config = Config.load(test_tmp_dir, %{tools: %{wasm: %{tool_paths: [tool_dir]}}})

      assert config.tool_paths == [Path.expand(tool_dir, test_tmp_dir)]
    end

    test "tool_paths parses comma-separated string", %{test_tmp_dir: test_tmp_dir} do
      dir1 = Path.join(test_tmp_dir, "tools1")
      dir2 = Path.join(test_tmp_dir, "tools2")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)

      config = Config.load(test_tmp_dir, %{tools: %{wasm: %{tool_paths: "#{dir1},#{dir2}"}}})

      assert Path.expand(dir1, test_tmp_dir) in config.tool_paths
      assert Path.expand(dir2, test_tmp_dir) in config.tool_paths
    end

    test "tool_paths handles empty list" do
      config = Config.load(".", %{tools: %{wasm: %{tool_paths: []}}})
      assert config.tool_paths == []
    end

    test "tool_paths filters nil values" do
      config = Config.load(".", %{tools: %{wasm: %{tool_paths: ["  "]}}})
      assert config.tool_paths == []
    end

    test "runtime_path parses as optional absolute path", %{test_tmp_dir: test_tmp_dir} do
      runtime_dir = Path.join(test_tmp_dir, "runtime")
      File.mkdir_p!(runtime_dir)

      config = Config.load(test_tmp_dir, %{tools: %{wasm: %{runtime_path: runtime_dir}}})

      assert config.runtime_path == Path.expand(runtime_dir, test_tmp_dir)
    end

    test "runtime_path returns nil for empty string" do
      config = Config.load(".", %{tools: %{wasm: %{runtime_path: ""}}})
      assert config.runtime_path == nil
    end

    test "runtime_path returns nil for whitespace string" do
      config = Config.load(".", %{tools: %{wasm: %{runtime_path: "   "}}})
      assert config.runtime_path == nil
    end

    test "runtime_path handles absolute paths", %{test_tmp_dir: test_tmp_dir} do
      runtime_dir = Path.join(test_tmp_dir, "runtime")
      File.mkdir_p!(runtime_dir)
      abs_path = Path.expand(runtime_dir)

      config = Config.load("/some/other/path", %{tools: %{wasm: %{runtime_path: abs_path}}})

      assert config.runtime_path == abs_path
    end

    test "cache_dir parses as optional path", %{test_tmp_dir: test_tmp_dir} do
      cache_dir = Path.join(test_tmp_dir, "cache")
      File.mkdir_p!(cache_dir)

      config = Config.load(test_tmp_dir, %{tools: %{wasm: %{cache_dir: cache_dir}}})

      assert config.cache_dir == Path.expand(cache_dir, test_tmp_dir)
    end

    test "cache_dir returns nil for empty string" do
      config = Config.load(".", %{tools: %{wasm: %{cache_dir: ""}}})
      assert config.cache_dir == nil
    end

    test "cache_dir handles absolute paths", %{test_tmp_dir: test_tmp_dir} do
      cache_dir = Path.join(test_tmp_dir, "cache")
      File.mkdir_p!(cache_dir)
      abs_path = Path.expand(cache_dir)

      config = Config.load("/some/other/path", %{tools: %{wasm: %{cache_dir: abs_path}}})

      assert config.cache_dir == abs_path
    end

    test "max_tool_invoke_depth parses positive integers" do
      config = Config.load(".", %{tools: %{wasm: %{max_tool_invoke_depth: 8}}})
      assert config.max_tool_invoke_depth == 8
    end

    test "max_tool_invoke_depth parses string integers" do
      config = Config.load(".", %{tools: %{wasm: %{max_tool_invoke_depth: "10"}}})
      assert config.max_tool_invoke_depth == 10
    end

    test "max_tool_invoke_depth enforces minimum of 1" do
      config = Config.load(".", %{tools: %{wasm: %{max_tool_invoke_depth: 0}}})
      assert config.max_tool_invoke_depth == 1

      config = Config.load(".", %{tools: %{wasm: %{max_tool_invoke_depth: -5}}})
      assert config.max_tool_invoke_depth == 1
    end

    test "handles string keys in settings map" do
      config = Config.load(".", %{"tools" => %{"wasm" => %{"enabled" => true}}})
      assert config.enabled == true
    end

    test "handles mixed atom and string keys" do
      config = Config.load(".", %{tools: %{"wasm" => %{enabled: true}}})
      assert config.enabled == true
    end

    test "auto_build parses boolean" do
      config = Config.load(".", %{tools: %{wasm: %{auto_build: false}}})
      assert config.auto_build == false

      config = Config.load(".", %{tools: %{wasm: %{auto_build: "false"}}})
      assert config.auto_build == false

      config = Config.load(".", %{tools: %{wasm: %{auto_build: true}}})
      assert config.auto_build == true
    end

    test "cache_compiled parses boolean" do
      config = Config.load(".", %{tools: %{wasm: %{cache_compiled: false}}})
      assert config.cache_compiled == false

      config = Config.load(".", %{tools: %{wasm: %{cache_compiled: "false"}}})
      assert config.cache_compiled == false

      config = Config.load(".", %{tools: %{wasm: %{cache_compiled: true}}})
      assert config.cache_compiled == true
    end

    test "discover_paths includes default paths and tool_paths", %{test_tmp_dir: test_tmp_dir} do
      tool_dir = Path.join(test_tmp_dir, "custom-tools")
      File.mkdir_p!(tool_dir)

      config = Config.load(test_tmp_dir, %{tools: %{wasm: %{tool_paths: [tool_dir]}}})

      assert Path.join(test_tmp_dir, ".lemon/wasm-tools") in config.discover_paths
      assert Path.expand(tool_dir, test_tmp_dir) in config.discover_paths
    end

    test "discover_paths removes duplicates", %{test_tmp_dir: test_tmp_dir} do
      tool_dir = Path.join(test_tmp_dir, ".lemon/wasm-tools")
      File.mkdir_p!(tool_dir)

      config = Config.load(test_tmp_dir, %{tools: %{wasm: %{tool_paths: [".lemon/wasm-tools"]}}})

      paths = config.discover_paths
      assert length(paths) == length(Enum.uniq(paths))
    end
  end
end
