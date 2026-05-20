defmodule CodingAgent.Wasm.ToolFactoryTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Wasm.ToolFactory
  alias AgentCore.Types.AgentTool

  defmodule FakeSidecar do
    use GenServer

    def start(opts) do
      GenServer.start(__MODULE__, opts)
    end

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call({:invoke, tool, params_json, context_json}, _from, state) do
      send(state.owner, {:fake_wasm_invoke, tool, params_json, context_json})
      {:reply, state.response, state}
    end
  end

  describe "build_inventory/3" do
    test "builds inventory entries from discovered tools" do
      # Use self() as a placeholder pid (execute fn is a closure, not called here)
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "hello_tool",
          description: "Says hello",
          schema_json:
            ~s({"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}),
          path: "/tools/hello.wasm",
          warnings: [],
          capabilities: %{http: false, tool_invoke: false},
          auth: nil
        }
      ]

      result = ToolFactory.build_inventory(sidecar_pid, discovered_tools)

      assert [{name, agent_tool, source}] = result
      assert name == "hello_tool"
      assert %AgentTool{} = agent_tool
      assert agent_tool.name == "hello_tool"
      assert agent_tool.description == "Says hello"
      assert agent_tool.label == "WASM: hello_tool"
      assert is_function(agent_tool.execute, 4)

      assert agent_tool.parameters == %{
               "type" => "object",
               "properties" => %{"name" => %{"type" => "string"}},
               "required" => ["name"]
             }

      assert {:wasm, metadata} = source
      assert metadata.path == "/tools/hello.wasm"
      assert is_binary(metadata.path_hash)
      assert metadata.source == :wasm
    end

    test "handles multiple discovered tools" do
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "tool_a",
          description: "Tool A",
          schema_json: "{}",
          path: "/a.wasm",
          warnings: [],
          capabilities: %{},
          auth: nil
        },
        %{
          name: "tool_b",
          description: "Tool B",
          schema_json: "{}",
          path: "/b.wasm",
          warnings: ["some warning"],
          capabilities: %{http: true},
          auth: nil
        }
      ]

      result = ToolFactory.build_inventory(sidecar_pid, discovered_tools)

      assert length(result) == 2
      names = Enum.map(result, fn {name, _, _} -> name end)
      assert "tool_a" in names
      assert "tool_b" in names
    end

    test "returns empty list for empty discovered tools" do
      result = ToolFactory.build_inventory(self(), [])
      assert result == []
    end

    test "handles invalid schema_json by falling back to empty object schema" do
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "bad_schema_tool",
          description: "Has bad schema",
          schema_json: "not valid json",
          path: "/bad.wasm",
          warnings: [],
          capabilities: %{},
          auth: nil
        }
      ]

      result = ToolFactory.build_inventory(sidecar_pid, discovered_tools)

      assert [{_name, agent_tool, _source}] = result
      assert agent_tool.parameters == %{"type" => "object", "properties" => %{}, "required" => []}
    end

    test "handles nil schema_json" do
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "nil_schema",
          description: "Nil schema",
          schema_json: nil,
          path: "/nil.wasm",
          warnings: [],
          capabilities: %{},
          auth: nil
        }
      ]

      result = ToolFactory.build_inventory(sidecar_pid, discovered_tools)

      assert [{_name, agent_tool, _source}] = result
      assert agent_tool.parameters == %{"type" => "object", "properties" => %{}, "required" => []}
    end

    test "passes cwd and session_id opts through to metadata" do
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "ctx_tool",
          description: "Context tool",
          schema_json: "{}",
          path: "/ctx.wasm",
          warnings: ["w1"],
          capabilities: %{http: true, secrets: true},
          auth: %{secret_name: "MY_KEY"}
        }
      ]

      result =
        ToolFactory.build_inventory(sidecar_pid, discovered_tools,
          cwd: "/my/project",
          session_id: "sess_123"
        )

      assert [{_name, _agent_tool, {:wasm, metadata}}] = result
      assert metadata.warnings == ["w1"]
      assert metadata.capabilities == %{http: true, secrets: true}
      assert metadata.auth == %{secret_name: "MY_KEY"}
    end

    test "schema_json with non-object JSON falls back to empty object schema" do
      sidecar_pid = self()

      discovered_tools = [
        %{
          name: "array_schema",
          description: "Array schema",
          schema_json: "[1,2,3]",
          path: "/arr.wasm",
          warnings: [],
          capabilities: %{},
          auth: nil
        }
      ]

      result = ToolFactory.build_inventory(sidecar_pid, discovered_tools)

      assert [{_name, agent_tool, _source}] = result
      assert agent_tool.parameters == %{"type" => "object", "properties" => %{}, "required" => []}
    end

    test "emits redacted telemetry around wasm tool execution" do
      {:ok, sidecar} =
        FakeSidecar.start(
          owner: self(),
          response:
            {:ok,
             %{
               output_json: Jason.encode!(%{"ok" => true}),
               error: nil,
               logs: [],
               details: %{"runtime" => "fake"}
             }}
        )

      [{_name, tool, _source}] =
        ToolFactory.build_inventory(sidecar, [
          %{
            name: "telemetry_wasm",
            description: "Telemetry test",
            schema_json: "{}",
            path: "/private/tools/telemetry.wasm",
            warnings: [],
            capabilities: %{},
            auth: nil
          }
        ])

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:coding_agent, :wasm, :tool, :start],
          [:coding_agent, :wasm, :tool, :stop]
        ])

      result =
        tool.execute.(
          "raw-wasm-call-id",
          %{"secret" => "do-not-leak"},
          nil,
          nil
        )

      assert_received {:fake_wasm_invoke, "telemetry_wasm", params_json, context_json}
      assert Jason.decode!(params_json) == %{"secret" => "do-not-leak"}
      assert is_binary(context_json)

      assert_received {
        [:coding_agent, :wasm, :tool, :start],
        ^ref,
        %{count: 1},
        start_meta
      }

      assert_received {
        [:coding_agent, :wasm, :tool, :stop],
        ^ref,
        %{count: 1, duration_us: duration_us},
        stop_meta
      }

      assert start_meta.host == :wasm
      assert start_meta.tool_name == "telemetry_wasm"
      assert is_binary(start_meta.wasm_path_hash)
      assert is_binary(start_meta.tool_call_hash)
      assert stop_meta.status == :ok
      assert stop_meta.wasm_path_hash == start_meta.wasm_path_hash
      assert duration_us >= 0
      assert result.trust == :untrusted

      payload = inspect({start_meta, stop_meta})
      refute payload =~ "raw-wasm-call-id"
      refute payload =~ "do-not-leak"
      refute payload =~ "/private/tools"

      :telemetry.detach(ref)
    end

    test "emits redacted exception telemetry when wasm invoke raises" do
      sidecar =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      monitor = Process.monitor(sidecar)
      send(sidecar, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^sidecar, :normal}

      [{_name, tool, _source}] =
        ToolFactory.build_inventory(sidecar, [
          %{
            name: "raising_wasm",
            description: "Raises",
            schema_json: "{}",
            path: "/private/tools/raising.wasm",
            warnings: [],
            capabilities: %{},
            auth: nil
          }
        ])

      telemetry_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:coding_agent, :wasm, :tool, :start],
          [:coding_agent, :wasm, :tool, :exception]
        ])

      assert catch_exit(
               tool.execute.("raw-raise-call-id", %{"secret" => "do-not-leak"}, nil, nil)
             )

      refute_received {
        [:coding_agent, :wasm, :tool, :stop],
        ^telemetry_ref,
        _measurements,
        _metadata
      }

      assert_received {
        [:coding_agent, :wasm, :tool, :start],
        ^telemetry_ref,
        %{count: 1},
        start_meta
      }

      assert_received {
        [:coding_agent, :wasm, :tool, :exception],
        ^telemetry_ref,
        %{count: 1, duration_us: duration_us},
        exception_meta
      }

      assert start_meta.tool_name == "raising_wasm"
      assert exception_meta.host == :wasm
      assert exception_meta.tool_name == "raising_wasm"
      assert exception_meta.kind == :exit
      assert is_binary(exception_meta.error_type)
      assert duration_us >= 0

      payload = inspect({start_meta, exception_meta})
      refute payload =~ "raw-raise-call-id"
      refute payload =~ "do-not-leak"
      refute payload =~ "private sidecar failure"
      refute payload =~ "/private/tools"

      :telemetry.detach(telemetry_ref)
    end
  end
end
