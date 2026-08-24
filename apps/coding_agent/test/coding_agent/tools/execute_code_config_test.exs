defmodule CodingAgent.Tools.ExecuteCodeConfigTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.ExecuteCode.Config

  @cwd "/tmp/execute-code-config-test"

  describe "load/2 defaults" do
    test "nil settings manager yields defaults with the tool disabled" do
      config = Config.load(@cwd, nil)

      assert config.enabled == false
      assert config.python_path == nil
      assert config.timeout_ms == 120_000
      assert config.max_rpc_calls == 100
      assert config.max_rpc_result_bytes == 5_242_880
      assert config.max_output_bytes == 50_000
      assert config.kernel_mode == "per_call"
      assert config.kernel_idle_timeout_ms == 1_800_000
      assert config.max_live_kernels == 16
      assert config.max_queued_cells_per_kernel == 8
      assert config.tools == Config.allowlist()
    end

    test "shapeless settings managers fall back to defaults" do
      for settings <- [%{}, %{tools: nil}, %{tools: %{}}, %{"tools" => %{}}, "not a map"] do
        assert Config.load(@cwd, settings).enabled == false
      end
    end

    test "allowlist/0 is the fixed five read-oriented tools" do
      assert Config.allowlist() == ["read", "grep", "find", "ls", "webfetch"]
    end
  end

  describe "load/2 key shapes" do
    test "atom-keyed settings parse" do
      config = Config.load(@cwd, %{tools: %{execute_code: %{enabled: true, timeout_ms: 9_000}}})

      assert config.enabled == true
      assert config.timeout_ms == 9_000
    end

    test "string-keyed settings parse" do
      config =
        Config.load(@cwd, %{
          "tools" => %{"execute_code" => %{"enabled" => true, "timeout_ms" => 9_000}}
        })

      assert config.enabled == true
      assert config.timeout_ms == 9_000
    end
  end

  describe "load/2 tool narrowing" do
    test "an explicit subset is preserved in configured order" do
      assert load_tools(["grep", "read"]) == ["grep", "read"]
    end

    test "unknown names are dropped -- config can never widen the allowlist" do
      assert load_tools(["read", "bash", "write"]) == ["read"]
    end

    test "an all-invalid list yields zero stubs rather than resetting to full" do
      assert load_tools(["bash", "write", "edit"]) == []
    end

    test "an empty list means the full allowlist" do
      assert load_tools([]) == Config.allowlist()
    end

    test "a comma or colon separated string is accepted" do
      assert load_tools("read, ls") == ["read", "ls"]
      assert load_tools("grep:find") == ["grep", "find"]
    end

    test "a non-list, non-string value falls back to the full allowlist" do
      assert load_tools(42) == Config.allowlist()
    end
  end

  describe "load/2 coercion" do
    test "boolean spellings" do
      for value <- [true, "true", "1", 1], do: assert(load_field(:enabled, value) == true)
      for value <- [false, "false", "0", 0], do: assert(load_field(:enabled, value) == false)
      # Unrecognised values keep the default rather than guessing.
      assert load_field(:enabled, "yes") == false
      assert load_field(:enabled, nil) == false
    end

    test "integer strings" do
      assert Config.load(@cwd, settings(%{timeout_ms: "120000"})).timeout_ms == 120_000
      assert Config.load(@cwd, settings(%{max_rpc_calls: "7"})).max_rpc_calls == 7
    end

    test "invalid integers keep the default and non-positive values clamp to 1" do
      assert Config.load(@cwd, settings(%{timeout_ms: "abc"})).timeout_ms == 120_000
      assert Config.load(@cwd, settings(%{max_output_bytes: 0})).max_output_bytes == 1
    end

    test "python_path is expanded, and blank means nil" do
      assert Config.load(@cwd, settings(%{python_path: "/usr/bin/python3"})).python_path ==
               "/usr/bin/python3"

      assert Config.load(@cwd, settings(%{python_path: "  "})).python_path == nil

      assert Config.load(@cwd, settings(%{python_path: "bin/py"})).python_path ==
               Path.join(@cwd, "bin/py")
    end
  end

  describe "load/2 kernel settings" do
    test "an explicit session mode parses from string and atom spellings" do
      assert load_field(:kernel_mode, "session") == "session"
      assert load_field(:kernel_mode, :session) == "session"
      assert load_field(:kernel_mode, "per_call") == "per_call"
    end

    test "an unrecognized mode never selects session" do
      for value <- ["persistent", "SESSION", "", true, 42, []] do
        assert load_field(:kernel_mode, value) == "per_call"
      end
    end

    test "kernel bounds coerce integer strings and clamp non-positive values to 1" do
      assert load_field(:kernel_idle_timeout_ms, "900000") == 900_000
      assert load_field(:max_live_kernels, "4") == 4
      assert load_field(:max_queued_cells_per_kernel, 2) == 2
      assert load_field(:max_live_kernels, 0) == 1
    end

    test "invalid kernel bounds keep their defaults" do
      assert load_field(:kernel_idle_timeout_ms, "abc") == 1_800_000
      assert load_field(:max_live_kernels, nil) == 16
      assert load_field(:max_queued_cells_per_kernel, []) == 8
    end
  end

  defp load_tools(value), do: Config.load(@cwd, settings(%{tools: value})).tools

  defp load_field(field, value),
    do: Config.load(@cwd, settings(%{field => value})) |> Map.get(field)

  defp settings(execute_code), do: %{tools: %{execute_code: execute_code}}
end
