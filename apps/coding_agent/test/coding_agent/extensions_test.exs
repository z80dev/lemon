defmodule CodingAgent.ExtensionsTest.Fixtures do
  @moduledoc false
  # Compiled extension-shaped modules for the collection APIs, which take
  # module lists and never load files.

  alias CodingAgent.ExtensionsTest.Fixtures
  alias LemonAgent.Types.{AgentTool, AgentToolResult}

  def tool(name) do
    %AgentTool{
      name: name,
      description: name,
      parameters: %{},
      label: name,
      execute: fn _, _, _, _ -> %AgentToolResult{content: []} end
    }
  end

  defmodule NoCallbacks do
  end

  defmodule ToolA do
    def tools(_cwd), do: [Fixtures.tool("dup_tool"), Fixtures.tool("unique_a")]
  end

  defmodule ToolB do
    def tools(_cwd), do: [Fixtures.tool("dup_tool")]
  end

  defmodule NonListTools do
    def tools(_cwd), do: :not_a_list
  end

  defmodule HooksA do
    def hooks, do: [on_message_start: fn _ -> :a end, on_agent_end: fn _ -> :a end]
  end

  defmodule HooksB do
    def hooks, do: [on_message_start: fn _ -> :b end]
  end

  defmodule RaisingName do
    def name, do: raise("name")
    def version, do: "1.0.0"
    def tools(_cwd), do: raise("tools")
    def hooks, do: raise("hooks")
    def providers, do: raise("providers")
  end

  defmodule RaisingVersion do
    def name, do: "raising-version"
    def version, do: raise("version")
    def capabilities, do: raise("capabilities")
    def config_schema, do: raise("config_schema")
  end

  defmodule ModelProviders do
    def providers do
      [
        %{
          type: :model,
          name: :ext_model_one,
          module: ExtModelOne,
          config: %{api_key_env: "TEST_API_KEY"}
        },
        %{type: :model, name: :ext_model_two, module: ExtModelTwo}
      ]
    end
  end

  defmodule ZZZConflict do
    def providers, do: [%{type: :model, name: :ordered_provider, module: ZZZModel}]
  end

  defmodule MMMConflict do
    def providers, do: [%{type: :model, name: :ordered_provider, module: MMMModel}]
  end

  defmodule AAAConflict do
    def providers, do: [%{type: :model, name: :ordered_provider, module: AAAModel}]
  end

  defmodule ShadowA do
    def providers, do: [%{type: :model, name: :shared_builtin, module: ShadowAModel}]
  end

  defmodule ShadowB do
    def providers, do: [%{type: :model, name: :shared_builtin, module: ShadowBModel}]
  end

  defmodule MemoryProvider do
    @behaviour LemonMemory.Provider

    @impl true
    def put(_doc, _opts), do: :ok
  end

  defmodule MixedTypes do
    def name, do: "mixed-type-provider"

    def providers do
      [
        %{type: :model, name: :my_model, module: MyModelModule},
        %{
          type: :memory,
          name: :my_memory,
          module: Fixtures.MemoryProvider,
          config: %{scopes: [:session], timeout_ms: 1234}
        },
        %{type: :storage, name: :my_storage, module: MyStorageModule},
        %{type: :tool_executor, name: :my_executor, module: MyExecutorModule},
        %{type: :custom_type, name: :my_custom, module: MyCustomModule}
      ]
    end
  end

  defmodule StringMemory do
    def name, do: "string-memory-provider"

    def providers do
      [
        %{
          "type" => "memory",
          "name" => "string_memory",
          "module" => Fixtures.MemoryProvider,
          "config" => %{"scopes" => ["workspace"], "label" => "String Memory"}
        }
      ]
    end
  end
end

defmodule CodingAgent.ExtensionsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Extensions
  alias CodingAgent.ExtensionsTest.Fixtures
  alias __MODULE__.NativeOwnershipExtension

  @moduletag :tmp_dir

  setup do
    providers =
      Map.new(LemonAi.ProviderRegistry.list(), fn api ->
        {api, LemonAi.ProviderRegistry.get!(api)}
      end)

    on_exit(fn ->
      Enum.each(LemonAi.ProviderRegistry.list() -- Map.keys(providers), fn api ->
        LemonAi.ProviderRegistry.unregister(api)
      end)

      Enum.each(providers, fn {api, module} ->
        if LemonAi.ProviderRegistry.get(api) != {:ok, module} do
          LemonAi.ProviderRegistry.register(api, module)
        end
      end)

      LemonMemory.Providers.unregister_provider("my_memory")
      LemonMemory.Providers.unregister_provider("string_memory")
      purge_generated_extensions()
    end)

    :ok
  end

  # Extension modules compiled from files live under this namespace so every
  # test gets unique module names and on_exit can unload them.
  defp ext(name), do: Module.concat([__MODULE__, Ext, name])

  defp purge_generated_extensions do
    prefix = Atom.to_string(__MODULE__) <> ".Ext."

    for {module, _} <- :code.all_loaded(),
        String.starts_with?(Atom.to_string(module), prefix) do
      :code.purge(module)
      :code.delete(module)
    end
  end

  # Writes an extension source file. Callbacks are `{name, body_source}`;
  # `name/0` and `version/0` default to valid values.
  defp write_ext(dir, file, module, callbacks \\ [], extra \\ "") do
    defs =
      [name: inspect(inspect(module)), version: ~s("1.0.0")]
      |> Keyword.merge(callbacks)
      |> Enum.map_join("\n", fn
        {:tools, body} -> "  def tools(_cwd), do: #{body}"
        {callback, body} -> "  def #{callback}, do: #{body}"
      end)

    path = Path.join(dir, file)
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    defmodule #{inspect(module)} do
      @behaviour CodingAgent.Extensions.Extension
    #{defs}
    end
    #{extra}
    """)

    path
  end

  defp write_broken(dir, file, module) do
    path = Path.join(dir, file)
    File.write!(path, "defmodule #{inspect(module)} do\n  def foo, do: \"unclosed\n")
    path
  end

  describe "native ownership boundaries" do
    setup %{tmp_dir: tmp_dir} do
      # The opt-in ledger is VM-global; background application work also records
      # launches. Keep these exact ownership assertions in their own VM.
      {:ok, peer, _} =
        :peer.start(%{
          connection: :standard_io,
          args: [~c"+S", ~c"2:2", ~c"-pa" | :code.get_path()]
        })

      on_exit(fn -> :peer.stop(peer) end)

      for app <- [:elixir, :logger, :crypto] do
        {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [app])
      end

      :peer.call(peer, Code, :eval_quoted, [
        quote do
          defmodule CodingAgent.ExtensionsTest.NativeOwnershipExtension do
            def name, do: observed(:name, "native-ownership")
            def version, do: observed(:version, "1.0.0")
            def tools(_cwd), do: observed(:tools, [])
            def hooks, do: observed(:hooks, [])
            def capabilities, do: observed(:capabilities, [])
            def config_schema, do: observed(:config_schema, %{})
            def providers, do: observed(:providers, [])

            defp observed(callback, value) do
              send(
                self(),
                {:ownership_callback, callback, length(LemonCore.NativeProcess.snapshot())}
              )

              value
            end
          end

          :ok
        end
      ])

      :ok =
        :peer.call(peer, LemonCore.NativeProcess, :configure!, [
          Path.join(tmp_dir, "native-ledger.dets")
        ])

      %{native_vm: peer}
    end

    test "validation records each callback before invoking it", %{native_vm: peer} do
      in_native_vm(
        peer,
        quote do
          assert {:error, _} = Extensions.validate_extension(CodingAgent.ExtensionsTest)
          assert LemonCore.NativeProcess.snapshot() == []
          assert :ok = Extensions.validate_extension(NativeOwnershipExtension)

          for {callback, count} <-
                Enum.with_index(
                  [:name, :version, :tools, :hooks, :capabilities, :config_schema, :providers],
                  1
                ) do
            assert_received {:ownership_callback, ^callback, ^count}
          end
        end
      )
    end

    test "tool, provider, hook discovery and metadata callbacks record ownership", %{
      native_vm: peer
    } do
      in_native_vm(
        peer,
        quote do
          assert [] = Extensions.get_tools([NativeOwnershipExtension], "/")
          assert_received {:ownership_callback, :tools, 1}
          assert [] = Extensions.get_providers([NativeOwnershipExtension])
          assert_received {:ownership_callback, :providers, 2}
          assert [] = Extensions.get_hooks([NativeOwnershipExtension])
          assert_received {:ownership_callback, :hooks, 3}
          assert [_] = Extensions.get_info([NativeOwnershipExtension])
          assert_received {:ownership_callback, :name, count}
          assert count > 3
        end
      )
    end

    test "all executable hook paths record before dispatch and retain failures", %{
      native_vm: peer
    } do
      in_native_vm(
        peer,
        quote do
          owner = self()

          observe = fn label ->
            send(owner, {:hook_ownership, label, length(LemonCore.NativeProcess.snapshot())})
          end

          assert :ok = Extensions.execute_hooks([], :missing)
          assert LemonCore.NativeProcess.snapshot() == []

          Extensions.execute_hooks(
            [
              on_test: [
                fn ->
                  observe.(:event)
                  raise "hook failure"
                end
              ]
            ],
            :on_test
          )

          assert_received {:hook_ownership, :event, 1}

          CodingAgent.Extensions.SessionHooks.session_start(
            [on_session_start: [fn _ -> observe.(:session) end]],
            %{}
          )

          assert_received {:hook_ownership, :session, 2}

          tool = %LemonAgent.Types.AgentTool{
            name: "ownership",
            execute: fn _, _, _, _ -> %LemonAgent.Types.AgentToolResult{content: []} end
          }

          wrapped =
            CodingAgent.Extensions.ToolHooks.wrap_tool(
              tool,
              [
                on_tool_call: [fn _ -> observe.(:call) end],
                on_tool_result: [fn _ -> observe.(:result) end]
              ],
              %{}
            )

          wrapped.execute.("call", %{}, nil, nil)
          assert_received {:hook_ownership, :call, 3}
          assert_received {:hook_ownership, :result, 4}

          records = LemonCore.NativeProcess.snapshot()
          assert length(records) == 4

          assert Enum.all?(records, fn
                   {_, %{backend: :unsupported, capacity_held: true}, _} -> true
                   _ -> false
                 end)
        end
      )
    end
  end

  defp in_native_vm(peer, body) do
    :peer.call(
      peer,
      Code,
      :eval_quoted,
      [
        quote do
          import ExUnit.Assertions
          unquote(body)
        end
      ],
      30_000
    )
  end

  describe "load_extensions/1" do
    test "concurrent loaders wait for an in-progress reload", %{tmp_dir: tmp_dir} do
      parent = self()

      holder =
        Task.async(fn ->
          Lemon.Reload.reload_system(
            compile: true,
            compile_fn: fn ->
              send(parent, :reload_locked)

              receive do
                :release_reload -> :ok
              end
            end
          )
        end)

      modules = [ConcurrentPlainLoadExtension, ConcurrentTrackedLoadExtension]
      on_exit(fn -> Enum.each(modules, &:code.delete/1) end)

      try do
        assert_receive :reload_locked, 1_000

        loaders =
          for {module, load} <-
                Enum.zip(modules, [
                  &Extensions.load_extensions/1,
                  &Extensions.load_extensions_with_errors/1
                ]) do
            dir = Path.join(tmp_dir, inspect(module))
            File.mkdir_p!(dir)

            File.write!(Path.join(dir, "extension.ex"), """
            defmodule #{inspect(module)} do
              @behaviour CodingAgent.Extensions.Extension
              def name, do: "#{inspect(module)}"
              def version, do: "1.0.0"
            end
            """)

            Task.async(fn ->
              send(parent, {:loader_started, self()})
              load.([dir])
            end)
          end

        for loader <- loaders do
          pid = loader.pid
          assert_receive {:loader_started, ^pid}, 1_000
        end

        waiting = Task.yield_many(loaders, 100)
        send(holder.pid, :release_reload)
        assert Enum.all?(waiting, fn {_task, reply} -> is_nil(reply) end)

        assert [
                 {:ok, [ConcurrentPlainLoadExtension]},
                 {:ok, [ConcurrentTrackedLoadExtension], [], []}
               ] =
                 Task.await_many(loaders, 30_000)
      after
        send(holder.pid, :release_reload)
        Task.await(holder)
      end
    end

    test "loads Extension modules from top-level .ex/.exs files, nested lib dirs and odd paths",
         %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root")
      special = Path.join(tmp_dir, "path with spaces & special!")
      real = Path.join(tmp_dir, "real")
      link = Path.join(tmp_dir, "link")

      write_ext(root, "top.ex", ext(Top), [], """
      defmodule #{inspect(ext(TopHelper))} do
        def helper, do: :ok
      end

      defmodule #{inspect(ext(LookAlike))} do
        def name, do: "look-alike"
        def version, do: "1.0.0"
      end
      """)

      write_ext(root, "script.exs", ext(Script))
      write_ext(root, "my_ext/lib/nested.ex", ext(Nested))
      File.write!(Path.join(root, "readme.md"), "# Extension")
      write_ext(special, "extension.ex", ext(Special))
      write_ext(real, "extension.ex", ext(Linked))
      :ok = File.ln_s(real, link)

      assert {:ok, extensions} = Extensions.load_extensions([root, special, link])

      assert Enum.sort(extensions) ==
               Enum.sort([ext(Top), ext(Script), ext(Nested), ext(Special), ext(Linked)])
    end

    test "ignores missing paths, non-Elixir files and files without loadable extensions", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "readme.md"), "# Extension")
      File.write!(Path.join(tmp_dir, "config.json"), "{}")
      File.write!(Path.join(tmp_dir, "script.sh"), "#!/bin/bash")
      File.write!(Path.join(tmp_dir, "empty.ex"), "")
      File.write!(Path.join(tmp_dir, "comments_only.ex"), "# No module definition here\n")
      write_broken(tmp_dir, "syntax_error.ex", ext(SyntaxError))

      assert Extensions.load_extensions([nil, "", "/nonexistent/path", tmp_dir]) == {:ok, []}
    end

    test "reloading a changed extension file replaces the previous version", %{tmp_dir: tmp_dir} do
      module = ext(Reloadable)
      write_ext(tmp_dir, "reloadable.ex", module, version: ~s("1.0.0"))
      assert {:ok, [^module]} = Extensions.load_extensions([tmp_dir])
      assert [%{version: "1.0.0"}] = Extensions.get_info([module])

      write_ext(tmp_dir, "reloadable.ex", module, version: ~s("2.0.0"))
      assert {:ok, [^module]} = Extensions.load_extensions([tmp_dir])
      assert [%{version: "2.0.0"}] = Extensions.get_info([module])
    end
  end

  describe "extension metadata" do
    test "get_info, get_source_path and list_extensions report a loaded extension", %{
      tmp_dir: tmp_dir
    } do
      module = ext(Rich)

      schema = %{
        "type" => "object",
        "properties" => %{
          "api_key" => %{"type" => "string", "description" => "API key", "secret" => true},
          "timeout" => %{"type" => "integer", "default" => 5000}
        },
        "required" => ["api_key"]
      }

      path =
        write_ext(
          tmp_dir,
          "rich.ex",
          module,
          [
            name: ~s("rich-metadata-ext"),
            version: ~s("2.0.0"),
            capabilities: "[:tools, :hooks]",
            config_schema: inspect(schema)
          ],
          "defmodule #{inspect(ext(RichHelper))} do\n  def ok, do: :ok\nend"
        )

      assert {:ok, [^module]} = Extensions.load_extensions([tmp_dir])

      info = %{
        name: "rich-metadata-ext",
        version: "2.0.0",
        module: module,
        source_path: path,
        capabilities: [:tools, :hooks],
        config_schema: schema
      }

      assert Extensions.get_info([module]) == [info]
      assert Extensions.get_source_path(module) == path
      assert Extensions.get_source_path(UnknownModule) == nil

      listed = Extensions.list_extensions()
      assert Enum.find(listed, &(&1.module == module)) == info
      refute Enum.any?(listed, &(&1.module == ext(RichHelper)))
    end

    test "get_info falls back to defaults for missing or raising callbacks" do
      assert Extensions.get_info([
               Fixtures.NoCallbacks,
               Fixtures.RaisingName,
               Fixtures.RaisingVersion
             ]) == [
               %{
                 name: "unknown",
                 version: "0.0.0",
                 module: Fixtures.NoCallbacks,
                 source_path: nil,
                 capabilities: [],
                 config_schema: %{}
               },
               %{
                 name: "unknown",
                 version: "1.0.0",
                 module: Fixtures.RaisingName,
                 source_path: nil,
                 capabilities: [],
                 config_schema: %{}
               },
               %{
                 name: "raising-version",
                 version: "0.0.0",
                 module: Fixtures.RaisingVersion,
                 source_path: nil,
                 capabilities: [],
                 config_schema: %{}
               }
             ]
    end
  end

  describe "tools and hooks" do
    test "get_tools collects tools and skips missing, raising or non-list tools/1", %{
      tmp_dir: tmp_dir
    } do
      assert Extensions.get_tools([], tmp_dir) == []

      tools =
        Extensions.get_tools(
          [
            Fixtures.ToolA,
            Fixtures.NoCallbacks,
            Fixtures.RaisingName,
            Fixtures.NonListTools,
            Fixtures.ToolB
          ],
          tmp_dir
        )

      assert Enum.map(tools, & &1.name) == ["dup_tool", "unique_a", "dup_tool"]
    end

    test "find_duplicate_tools maps tool names provided by several extensions", %{
      tmp_dir: tmp_dir
    } do
      assert Extensions.find_duplicate_tools([Fixtures.ToolA, Fixtures.ToolB], tmp_dir) ==
               %{"dup_tool" => [Fixtures.ToolA, Fixtures.ToolB]}

      assert Extensions.find_duplicate_tools([Fixtures.ToolA], tmp_dir) == %{}
      assert Extensions.find_duplicate_tools([], tmp_dir) == %{}
    end

    test "get_hooks groups hooks by event and skips missing or raising hooks/0" do
      assert Extensions.get_hooks([]) == []

      hooks =
        Extensions.get_hooks([
          Fixtures.HooksA,
          Fixtures.NoCallbacks,
          Fixtures.RaisingName,
          Fixtures.HooksB
        ])

      assert Enum.sort(Keyword.keys(hooks)) == [:on_agent_end, :on_message_start]
      assert Enum.map(hooks[:on_message_start], & &1.(nil)) == [:a, :b]
      assert length(hooks[:on_agent_end]) == 1
    end

    test "execute_hooks passes args to every hook and survives failing hooks" do
      parent = self()

      hooks = [
        on_test: [
          fn arg -> send(parent, {:first, arg}) end,
          fn _ -> raise "boom" end,
          fn _ -> throw(:boom) end,
          fn _ -> exit(:boom) end,
          fn _one, _two -> :wrong_arity end,
          nil,
          "not a function",
          fn arg -> send(parent, {:last, arg}) end
        ],
        on_zero: [fn -> send(parent, :zero_arity) end]
      ]

      assert :ok = Extensions.execute_hooks(hooks, :on_test, ["value"])
      assert_received {:first, "value"}
      assert_received {:last, "value"}

      assert :ok = Extensions.execute_hooks(hooks, :on_zero)
      assert_received :zero_arity

      assert :ok = Extensions.execute_hooks([], :nonexistent, [])
    end
  end

  describe "load_extensions_with_errors/1 and last_load_errors/0" do
    test "returns empty results for missing paths" do
      assert Extensions.load_extensions_with_errors(["/nonexistent/path"]) == {:ok, [], [], []}
    end

    test "separates loaded extensions from compile errors and caches the errors", %{
      tmp_dir: tmp_dir
    } do
      valid = ext(Valid)
      write_ext(tmp_dir, "valid.ex", valid)
      bad_path = write_broken(tmp_dir, "invalid.ex", ext(Invalid))
      started_at = System.system_time(:millisecond)

      assert {:ok, [^valid], [error], []} = Extensions.load_extensions_with_errors([tmp_dir])
      assert error.source_path == bad_path
      assert is_binary(error.error_message) and error.error_message != ""

      assert {[^error], loaded_at} = Extensions.last_load_errors()
      assert loaded_at >= started_at
    end

    test "a later load replaces the cached errors and timestamp", %{tmp_dir: tmp_dir} do
      first_path = write_broken(tmp_dir, "first_bad.ex", ext(FirstBad))
      {:ok, _, _, _} = Extensions.load_extensions_with_errors([tmp_dir])
      assert {[%{source_path: ^first_path}], first_at} = Extensions.last_load_errors()

      Process.sleep(5)
      File.rm!(first_path)
      second_path = write_broken(tmp_dir, "second_bad.ex", ext(SecondBad))
      {:ok, _, _, _} = Extensions.load_extensions_with_errors([tmp_dir])

      assert {[%{source_path: ^second_path}], second_at} = Extensions.last_load_errors()
      assert second_at > first_at
    end

    test "validation failures are reported apart from cached load errors", %{tmp_dir: tmp_dir} do
      module = ext(ValidationPersist)
      path = write_ext(tmp_dir, "validation_persist.ex", module, name: ":not_a_string")

      assert {:ok, [], [], [%{module: ^module, source_path: ^path, errors: [message]}]} =
               Extensions.load_extensions_with_errors([tmp_dir])

      assert message =~ "name/0 must return a string"
      assert {[], loaded_at} = Extensions.last_load_errors()
      assert is_integer(loaded_at)
    end

    test "rejects extensions whose callbacks raise or return the wrong type", %{
      tmp_dir: tmp_dir
    } do
      cases = [
        {:name, ~s(raise "boom"), "name/0 raised an error"},
        {:version, ~s(raise "boom"), "version/0 raised an error"},
        {:tools, ~s(raise "boom"), "tools/1 raised an error"},
        {:hooks, ~s(raise "boom"), "hooks/0 raised an error"},
        {:capabilities, ~s(raise "boom"), "capabilities/0 raised an error"},
        {:config_schema, ~s(raise "boom"), "config_schema/0 raised an error"},
        {:providers, ~s(raise "boom"), "providers/0 raised an error"},
        {:name, ":not_a_string", "name/0 must return a string"},
        {:version, "100", "version/0 must return a string"},
        {:tools, ":not_a_list", "tools/1 must return a list"},
        {:hooks, ~s("not a keyword list"), "hooks/0 must return a keyword list"},
        {:capabilities, ":not_a_list", "capabilities/0 must return a list"},
        {:config_schema, "[]", "config_schema/0 must return a map"},
        {:providers, "%{invalid: :structure}", "providers/0 must return a list"}
      ]

      expected =
        for {{callback, body, message}, index} <- Enum.with_index(cases), into: %{} do
          module = ext(:"Invalid#{index}")
          write_ext(tmp_dir, "invalid_#{index}.ex", module, [{callback, body}])
          {module, [message]}
        end

      multiple = ext(MultipleInvalid)

      write_ext(tmp_dir, "multiple_invalid.ex", multiple,
        name: "123",
        version: ":atom",
        tools: ~s("string"),
        hooks: ":atom"
      )

      expected =
        Map.put(expected, multiple, [
          "name/0 must return a string",
          "version/0 must return a string",
          "tools/1 must return a list",
          "hooks/0 must return a keyword list"
        ])

      assert {:ok, [], [], validation_errors} = Extensions.load_extensions_with_errors([tmp_dir])
      errors_by_module = Map.new(validation_errors, &{&1.module, &1.errors})
      assert Enum.sort(Map.keys(errors_by_module)) == Enum.sort(Map.keys(expected))

      for {module, messages} <- expected do
        errors = errors_by_module[module]
        assert length(errors) == length(messages), "#{inspect(module)}: #{inspect(errors)}"

        for message <- messages do
          assert Enum.any?(errors, &String.contains?(&1, message)),
                 "#{inspect(module)} lacks #{inspect(message)}: #{inspect(errors)}"
        end
      end
    end
  end

  describe "build_status_report/3" do
    test "summarizes loaded extensions, load errors and tool conflicts", %{tmp_dir: tmp_dir} do
      write_ext(tmp_dir, "status.ex", ext(Status),
        name: ~s("status-report-ext"),
        version: ~s("2.0.0"),
        capabilities: "[:tools]"
      )

      bad_path = write_broken(tmp_dir, "bad.ex", ext(StatusBad))
      {:ok, extensions, errors, []} = Extensions.load_extensions_with_errors([tmp_dir])

      report = Extensions.build_status_report(extensions, errors, cwd: tmp_dir)

      assert report.total_loaded == 1
      assert report.total_errors == 1
      assert is_integer(report.loaded_at)

      assert [%{name: "status-report-ext", version: "2.0.0", capabilities: [:tools]}] =
               report.extensions

      assert [%{source_path: ^bad_path, error_message: message}] = report.load_errors
      assert is_binary(message)
      assert %{conflicts: _, total_tools: _} = report.tool_conflicts
      assert report.provider_registration == nil
    end

    test "uses precomputed reports and omits tool conflicts without cwd" do
      report = Extensions.build_status_report([], [], [])
      assert report.tool_conflicts == nil
      assert report.provider_registration == nil

      conflict_report = %{
        conflicts: [],
        total_tools: 5,
        builtin_count: 5,
        extension_count: 0,
        shadowed_count: 0
      }

      provider_report = %{
        registered: [%{type: :model, name: :test, module: TestMod, extension: TestExt}],
        conflicts: [],
        total_registered: 1,
        total_conflicts: 0
      }

      report =
        Extensions.build_status_report([], [],
          tool_conflict_report: conflict_report,
          provider_registration: provider_report
        )

      assert report.tool_conflicts == conflict_report
      assert report.provider_registration == provider_report
    end
  end

  describe "clear_extension_cache/0" do
    test "unloads extensions, forgets source paths and load errors, and reloads cleanly", %{
      tmp_dir: tmp_dir
    } do
      module = ext(Cleared)
      path = write_ext(tmp_dir, "cleared.ex", module)
      write_broken(tmp_dir, "bad.ex", ext(ClearedBad))

      assert {:ok, [^module], [_error], []} = Extensions.load_extensions_with_errors([tmp_dir])
      assert Extensions.get_source_path(module) == path
      assert {[_error], loaded_at} = Extensions.last_load_errors()
      assert is_integer(loaded_at)
      assert Enum.any?(Extensions.list_extensions(), &(&1.module == module))

      assert :ok = Extensions.clear_extension_cache()

      assert Extensions.get_source_path(module) == nil
      refute Code.ensure_loaded?(module)
      refute Enum.any?(Extensions.list_extensions(), &(&1.module == module))
      assert Extensions.last_load_errors() == {[], nil}
      assert :ok = Extensions.clear_extension_cache()
      assert Extensions.last_load_errors() == {[], nil}

      assert {:ok, [^module], [_error], []} = Extensions.load_extensions_with_errors([tmp_dir])
      assert Extensions.get_source_path(module) == path
    end
  end

  describe "providers" do
    test "get_providers normalizes specs and skips raising providers/0" do
      assert Extensions.get_providers([]) == []

      assert Extensions.get_providers([
               Fixtures.ModelProviders,
               Fixtures.RaisingName,
               Fixtures.NoCallbacks
             ]) == [
               {%{
                  type: :model,
                  name: :ext_model_one,
                  module: ExtModelOne,
                  config: %{api_key_env: "TEST_API_KEY"}
                }, Fixtures.ModelProviders},
               {%{type: :model, name: :ext_model_two, module: ExtModelTwo, config: %{}},
                Fixtures.ModelProviders}
             ]
    end

    test "register_extension_providers registers model providers" do
      assert Extensions.register_extension_providers([]) == %{
               registered: [],
               conflicts: [],
               total_registered: 0,
               total_conflicts: 0
             }

      report = Extensions.register_extension_providers([Fixtures.ModelProviders])

      assert report.total_registered == 2
      assert report.conflicts == []

      assert Enum.sort_by(report.registered, & &1.name) == [
               %{
                 type: :model,
                 name: :ext_model_one,
                 module: ExtModelOne,
                 extension: Fixtures.ModelProviders
               },
               %{
                 type: :model,
                 name: :ext_model_two,
                 module: ExtModelTwo,
                 extension: Fixtures.ModelProviders
               }
             ]

      assert LemonAi.ProviderRegistry.get(:ext_model_one) == {:ok, ExtModelOne}
      assert LemonAi.ProviderRegistry.get(:ext_model_two) == {:ok, ExtModelTwo}
    end

    test "the alphabetically first extension module wins a provider-name conflict" do
      report =
        Extensions.register_extension_providers([
          Fixtures.ZZZConflict,
          Fixtures.MMMConflict,
          Fixtures.AAAConflict
        ])

      assert report.total_registered == 1

      assert report.conflicts == [
               %{
                 type: :model,
                 name: :ordered_provider,
                 winner: Fixtures.AAAConflict,
                 shadowed: [Fixtures.MMMConflict, Fixtures.ZZZConflict]
               }
             ]

      assert LemonAi.ProviderRegistry.get(:ordered_provider) == {:ok, AAAModel}
    end

    test "an already registered built-in provider shadows extension providers" do
      LemonAi.ProviderRegistry.register(:shared_builtin, SharedBuiltinModule)

      assert %{total_registered: 0, conflicts: []} =
               Extensions.register_extension_providers([Fixtures.ShadowA])

      report = Extensions.register_extension_providers([Fixtures.ShadowA, Fixtures.ShadowB])

      assert report.total_registered == 0

      assert report.conflicts == [
               %{
                 type: :model,
                 name: :shared_builtin,
                 winner: :builtin,
                 shadowed: [Fixtures.ShadowA, Fixtures.ShadowB]
               }
             ]

      assert LemonAi.ProviderRegistry.get(:shared_builtin) == {:ok, SharedBuiltinModule}
    end

    test "registers model and memory providers and skips unsupported types" do
      report = Extensions.register_extension_providers([Fixtures.MixedTypes])

      assert report.total_registered == 2
      assert report.total_conflicts == 0
      assert Enum.any?(report.registered, &(&1.type == :model and &1.name == :my_model))
      assert Enum.any?(report.registered, &(&1.type == :memory and &1.name == :my_memory))
      assert LemonAi.ProviderRegistry.registered?(:my_model)
      refute LemonAi.ProviderRegistry.registered?(:my_storage)
      refute LemonAi.ProviderRegistry.registered?(:my_executor)
      refute LemonAi.ProviderRegistry.registered?(:my_custom)

      memory_provider =
        Enum.find(LemonMemory.Providers.status().providers, &(&1.id == "my_memory"))

      assert memory_provider.source == "extension:mixed-type-provider"
      assert memory_provider.scopes == ["session"]
      assert memory_provider.timeout_ms == 1234

      assert :ok = Extensions.unregister_extension_providers(report)
      refute LemonAi.ProviderRegistry.registered?(:my_model)
      refute Enum.any?(LemonMemory.Providers.status().providers, &(&1.id == "my_memory"))
    end

    test "registers string-keyed memory providers" do
      report = Extensions.register_extension_providers([Fixtures.StringMemory])

      assert [%{type: :memory, name: "string_memory"}] = report.registered

      provider =
        Enum.find(LemonMemory.Providers.status().providers, &(&1.id == "string_memory"))

      assert provider.scopes == ["workspace"]
      assert provider.source == "extension:string-memory-provider"

      Extensions.unregister_extension_providers(report)
      refute Enum.any?(LemonMemory.Providers.status().providers, &(&1.id == "string_memory"))
    end

    test "unregister_extension_providers accepts nil and empty reports" do
      assert :ok = Extensions.unregister_extension_providers(nil)

      assert :ok =
               Extensions.unregister_extension_providers(%{
                 registered: [],
                 conflicts: [],
                 total_registered: 0,
                 total_conflicts: 0
               })
    end
  end
end
