defmodule CodingAgent.Tools.LspTest do
  use ExUnit.Case, async: false

  alias CodingAgent.FileReadTracker
  alias CodingAgent.ToolRegistry
  alias CodingAgent.Tools.Lsp
  alias CodingAgent.Tools.Lsp.{Client, Text}
  alias LemonAgent.Types.AgentToolResult

  @env "LEMON_LSP_CLANGD_COMMAND"

  setup do
    if System.find_executable("elixir") == nil do
      {:skip, "elixir executable is not on PATH for the fake language server"}
    else
      tmp = Path.join(System.tmp_dir!(), "lsp_tool_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "src"))
      tmp = Text.realpath(tmp)
      File.mkdir_p!(Path.join(tmp, ".lemon"))

      File.write!(
        Path.join(tmp, ".lemon/config.toml"),
        "[runtime.tools.lsp]\nidle_timeout_ms = 0\n"
      )

      server = Path.join(tmp, "fake_lsp_server.exs")
      File.write!(server, fake_server_script())
      File.chmod!(server, 0o755)
      File.write!(Path.join(tmp, "compile_flags.txt"), "-std=c11\n")
      File.write!(Path.join(tmp, "src/main.c"), "/* 😀 */ int value = 1;\nint other = value;\n")

      previous = System.get_env(@env)
      System.put_env(@env, server)
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      session_id = "lsp-tool-test-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        Enum.each(Client.list(session_id), &Client.stop(&1.pid))
        send(owner, :stop)
        if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
        File.rm_rf!(tmp)
      end)

      opts = [session_id: session_id, session_pid: owner, filesystem_checkpoints: false]
      {:ok, tmp: tmp, opts: opts, owner: owner, session_id: session_id}
    end
  end

  defp run(ctx, params) do
    tool = Lsp.tool(ctx.tmp, ctx.opts)
    tool.execute.("call-1", params, nil, nil)
  end

  defp text!(%AgentToolResult{content: [%{text: text}]}), do: text

  test "navigation sends UTF-16 positions and reports code-point path:line:col", ctx do
    # Obtain the tool exactly as sessions do.
    tool = Enum.find(ToolRegistry.get_tools(ctx.tmp, ctx.opts), &(&1.name == "lsp"))
    exec = &tool.execute.("call", &1, nil, nil)

    definition =
      exec.(%{"action" => "definition", "file" => "src/main.c", "line" => 2, "symbol" => "value"})

    assert text!(definition) ==
             """
             Found 1 definition(s):
               src/main.c:1:13
                 1: /* 😀 */ int value = 1;
                 2: int other = value;\
             """

    assert definition.trust == :untrusted

    hover =
      exec.(%{"action" => "hover", "file" => "src/main.c", "line" => 1, "symbol" => "value"})

    assert text!(hover) == "**hover** at 0:13"

    hover = exec.(%{"action" => "hover", "file" => "src/main.c", "line" => 1, "column" => 2})
    assert text!(hover) == "**hover** at 0:1"

    references =
      exec.(%{"action" => "references", "file" => "src/main.c", "line" => 1, "symbol" => "value"})

    assert text!(references) =~ "Found 60 reference(s):"
    assert text!(references) =~ "... 10 additional reference(s) shown without context"
  end

  test "diagnostics wait for the publish matching the synced document", ctx do
    result = run(ctx, %{"action" => "diagnostics", "file" => "src/main.c"})

    assert text!(result) ==
             "src/main.c: 1 error(s):\n  src/main.c:1:1 [error] [fake] fake problem v1 (E1)"

    File.write!(Path.join(ctx.tmp, "src/main.c"), "int changed = 0;\n")
    result = run(ctx, %{"action" => "diagnostics", "file" => "src/main.c"})
    assert text!(result) =~ "fake problem v2"
  end

  test "catalog language IDs, capabilities and reload", ctx do
    for path <- ["sample.rb", "sample.cs", "sample.swift", "sample.tsx", "unknown.xyz"] do
      assert Client.language_id(path) == LemonLsp.Servers.language_id(path)
    end

    result = run(ctx, %{"action" => "capabilities", "file" => "src/main.c"})
    assert result.details.capabilities["renameProvider"]["prepareProvider"]
    [%{pid: before}] = Client.list(ctx.session_id)
    assert %AgentToolResult{} = run(ctx, %{"action" => "reload", "file" => "src/main.c"})
    [%{pid: after_reload}] = Client.list(ctx.session_id)
    refute before == after_reload
    refute Process.alive?(before)
    assert %AgentToolResult{} = run(ctx, %{"action" => "reload"})
    [%{pid: after_scope}] = Client.list(ctx.session_id)
    refute after_reload == after_scope
  end

  test "workspace diagnostics aggregate published files without starting servers", ctx do
    assert run(ctx, %{"action" => "diagnostics", "file" => "*"}).details.count == 0
    assert Client.list(ctx.session_id) == []
    run(ctx, %{"action" => "diagnostics", "file" => "src/main.c"})
    File.write!(Path.join(ctx.tmp, "src/second.c"), "int second;\n")
    run(ctx, %{"action" => "diagnostics", "file" => "src/second.c"})
    result = run(ctx, %{"action" => "diagnostics", "file" => "*"})
    assert result.details.count == 2
    assert text!(result) =~ "src/main.c:1:1"
    assert text!(result) =~ "src/second.c:1:1"
  end

  test "file rename previews edits before moving and notifies only after apply", ctx do
    params = %{"action" => "rename_file", "file" => "src/main.c", "new_name" => "src/moved.c"}
    original = File.read!(Path.join(ctx.tmp, "src/main.c"))
    preview = run(ctx, params)
    assert text!(preview) =~ "File rename preview"
    assert File.read!(Path.join(ctx.tmp, "src/main.c")) == original
    refute File.exists?(Path.join(ctx.tmp, "src/moved.c"))
    applied = run(ctx, Map.put(params, "apply", true))
    assert applied.details.applied
    refute File.exists?(Path.join(ctx.tmp, "src/main.c"))
    assert File.read!(Path.join(ctx.tmp, "src/moved.c")) == "// renamed\n" <> original
    state = run(ctx, %{"action" => "request", "file" => "src/moved.c", "query" => "fake/renamed"})
    assert text!(state) =~ "moved.c"
  end

  test "rename previews by default and applies atomically with apply: true", ctx do
    path = Path.join(ctx.tmp, "src/main.c")
    original = File.read!(path)

    params = %{
      "action" => "rename",
      "file" => "src/main.c",
      "line" => 1,
      "symbol" => "value",
      "new_name" => "total"
    }

    preview = run(ctx, params)

    assert text!(preview) ==
             "Rename preview (2 change(s); pass apply: true to write them):\n" <>
               "  CREATE: src/created.c\n  src/main.c: 1 edit (line 1)"

    assert File.read!(path) == original

    FileReadTracker.record(ctx.opts, path, original)
    applied = run(ctx, Map.put(params, "apply", true))

    assert text!(applied) =~ "Applied rename to total:"
    assert File.read!(path) == "/* 😀 */ int total = 1;\nint other = value;\n"
    assert File.exists?(Path.join(ctx.tmp, "src/created.c"))
    assert Enum.sort(applied.details.changed_files) == ["src/created.c", "src/main.c"]
    assert :ok = FileReadTracker.check(ctx.opts, path, File.read!(path))

    # The server was told about the new content.
    state = run(ctx, %{"action" => "request", "query" => "fake/state", "file" => "src/main.c"})
    assert text!(state) =~ ~s("#{Text.path_to_uri(path)}": 2)
  end

  test "code actions list, resolve and execute commands that send applyEdit", ctx do
    ctx = checkpoint_context(ctx)
    path = Path.join(ctx.tmp, "src/main.c")
    listing = run(ctx, %{"action" => "code_actions", "file" => "src/main.c", "line" => 1})

    assert listing.details.count == 4
    assert text!(listing) =~ "Diagnostics in context: 1"

    resolved =
      run(ctx, %{
        "action" => "code_actions",
        "file" => "src/main.c",
        "line" => 1,
        "apply" => true,
        "query" => "0"
      })

    assert text!(resolved) =~ ~s(Applied "Insert header")
    assert File.read!(path) =~ ~r/^\/\/ header\n/
    before_command = File.read!(path)

    command =
      run(ctx, %{
        "action" => "code_actions",
        "file" => "src/main.c",
        "line" => 2,
        "apply" => true,
        "query" => "run fixer"
      })

    assert text!(command) =~ "Executed command: fake.fix"
    assert File.read!(path) == "// fixed again\n// fixed\n" <> before_command
    assert Enum.sort(command.details.changed_files) == ["src/fixed.c", "src/main.c"]
    assert length(command.details.checkpoint_ids) == 3
    refute Map.has_key?(command.details, :checkpoint_id)
    assert File.read!(Path.join(ctx.tmp, "src/fixed.c")) == ""

    for id <- Enum.reverse(command.details.checkpoint_ids) do
      assert {:ok, _} = CodingAgent.Checkpoint.restore_filesystem(id)
    end

    assert File.read!(path) == before_command
    refute File.exists?(Path.join(ctx.tmp, "src/fixed.c"))

    missing =
      run(ctx, %{
        "action" => "code_actions",
        "file" => "src/main.c",
        "line" => 1,
        "apply" => true,
        "query" => "nope"
      })

    assert text!(missing) =~ ~s(No code action matches "nope")
  end

  test "partial command failure retains direct and captured edit checkpoints", ctx do
    ctx = checkpoint_context(ctx)
    path = Path.join(ctx.tmp, "src/main.c")
    original = File.read!(path)

    result =
      run(ctx, %{
        "action" => "code_actions",
        "file" => "src/main.c",
        "line" => 1,
        "apply" => true,
        "query" => "partial fixer"
      })

    refute result.details.success
    assert result.details.applied
    assert length(result.details.checkpoint_ids) == 3
    assert Enum.sort(result.details.changed_files) == ["src/fixed.c", "src/main.c"]
    assert File.read!(path) != original
    assert File.exists?(Path.join(ctx.tmp, "src/fixed.c"))

    for id <- Enum.reverse(result.details.checkpoint_ids) do
      assert {:ok, _} = CodingAgent.Checkpoint.restore_filesystem(id)
    end

    assert File.read!(path) == original
    refute File.exists?(Path.join(ctx.tmp, "src/fixed.c"))
  end

  test "abort retains checkpoints already published before an in-flight batch", ctx do
    ctx = checkpoint_context(ctx)
    parent = self()
    signal = LemonAgent.AbortSignal.new()
    on_exit(fn -> LemonAgent.AbortSignal.clear(signal) end)

    opts =
      Keyword.put(ctx.opts, :on_checkpoint, fn checkpoint ->
        send(parent, {:checkpoint_ready, self(), checkpoint.id})
        receive do: (:continue -> :ok)
      end)

    path = Path.join(ctx.tmp, "src/main.c")
    original = File.read!(path)

    task =
      Task.async(fn ->
        Lsp.execute(
          "abort-call",
          %{
            "action" => "code_actions",
            "file" => "src/main.c",
            "line" => 1,
            "apply" => true,
            "query" => "run fixer"
          },
          signal,
          nil,
          ctx.tmp,
          opts
        )
      end)

    assert_receive {:checkpoint_ready, first_worker, first_id}, 20_000
    send(first_worker, :continue)
    assert_receive {:checkpoint_ready, _second_worker, second_id}, 20_000
    assert File.read!(path) == "// fixed\n" <> original
    LemonAgent.AbortSignal.abort(signal)
    result = Task.await(task, 2_000)

    refute result.details.success
    assert result.details.checkpoint_ids == [first_id, second_id]

    for id <- Enum.reverse(result.details.checkpoint_ids) do
      assert {:ok, _} = CodingAgent.Checkpoint.restore_filesystem(id)
    end

    assert File.read!(path) == original
    refute File.exists?(Path.join(ctx.tmp, "src/fixed.c"))
  end

  defp checkpoint_context(ctx) do
    paths = Application.get_env(:lemon_core, :paths, [])

    Application.put_env(
      :lemon_core,
      :paths,
      Keyword.put(paths, :checkpoint_dir, Path.join(ctx.tmp, "checkpoints"))
    )

    on_exit(fn -> Application.put_env(:lemon_core, :paths, paths) end)
    %{ctx | opts: Keyword.put(ctx.opts, :filesystem_checkpoints, true)}
  end

  test "surfaces server errors, unsupported files and missing servers", ctx do
    assert {:error, message} =
             run(ctx, %{"action" => "request", "file" => "src/main.c", "query" => "fake/missing"})

    assert message =~ "clangd returned an error for fake/missing: Method not found (code -32601)"

    File.write!(Path.join(ctx.tmp, "notes.txt"), "x")
    assert {:error, message} = run(ctx, %{"action" => "diagnostics", "file" => "notes.txt"})
    assert message =~ "No language server is registered for .txt files"

    System.put_env(@env, Path.join(ctx.tmp, "missing-clangd"))
    assert {:error, message} = run(ctx, %{"action" => "diagnostics", "file" => "src/main.c"})
    assert message =~ "is not installed. Install clangd and put it on PATH."
  end

  test "servers stop when the owning session process exits", ctx do
    assert %AgentToolResult{} =
             run(ctx, %{"action" => "hover", "file" => "src/main.c", "line" => 1})

    assert [%{pid: pid, server_id: :clangd, root: root}] = Client.list(ctx.session_id)
    assert root == ctx.tmp
    ref = Process.monitor(pid)
    assert {:ok, %{session_id: managed_session_id}} = Client.sync(pid, nil, 5_000)

    send(ctx.owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    # Other idle servers may disappear at the same time. Check this lease's
    # managed server, not a delta in the process-global active count.
    assert {:error, :unknown_lsp_session} =
             LemonLsp.ServerManager.stop_session(managed_session_id)
  end

  test "two coding sessions share a process and authoritative document versions", ctx do
    other = second_session(ctx)
    first_pid = raw_result(ctx, "fake/pid")
    assert raw_result(other, "fake/pid") == first_pid
    [first] = Client.list(ctx.session_id)
    [second] = Client.list(other.session_id)
    refute first.pid == second.pid
    path = Path.join(ctx.tmp, "src/main.c")
    assert {:ok, a} = Client.sync(first.pid, path, 5_000)
    assert {:ok, b} = Client.sync(second.pid, path, 5_000)
    assert a.session_id == b.session_id
    assert a.version == 1
    assert b.version == 1
    File.write!(path, "int latest = 2;\n")
    assert {:ok, %{version: 2}} = Client.sync(second.pid, path, 5_000)
    assert {:ok, %{version: 2, synced: :unchanged}} = Client.sync(first.pid, path, 5_000)

    assert text!(run(ctx, %{"action" => "diagnostics", "file" => "src/main.c"})) =~
             "fake problem v2"

    assert text!(run(other, %{"action" => "diagnostics", "file" => "src/main.c"})) =~
             "fake problem v2"

    Client.stop(first.pid)
    assert raw_result(other, "fake/pid") == first_pid
  end

  test "configuration changes select a new shared process without reusing stale clients", ctx do
    before = raw_result(ctx, "fake/pid")

    File.write!(Path.join(ctx.tmp, ".lemon/config.toml"), """
    [runtime.tools.lsp]
    idle_timeout_ms = 0
    [runtime.tools.lsp.servers.clangd]
    args = ["changed-config"]
    """)

    LemonCore.Config.reload(ctx.tmp)
    refute raw_result(ctx, "fake/pid") == before
    assert raw_result(ctx, "fake/config")["args"] == ["changed-config"]

    File.write!(Path.join(ctx.tmp, ".lemon/config.toml"), """
    [runtime.tools.lsp]
    idle_timeout_ms = 0
    [runtime.tools.lsp.servers.clangd]
    disabled = true
    """)

    LemonCore.Config.reload(ctx.tmp)
    assert run(ctx, %{"action" => "reload", "file" => "*"}).details.count == 0
    assert Client.list(ctx.session_id) == []
  end

  test "a crash reports all in-flight calls and restarts on the next use", ctx do
    other = second_session(ctx)
    before = raw_result(ctx, "fake/pid")
    assert raw_result(other, "fake/pid") == before

    requests =
      for context <- [ctx, other],
          do:
            Task.async(fn ->
              run(context, %{
                "action" => "request",
                "file" => "src/main.c",
                "query" => "fake/hold"
              })
            end)

    assert wait_pending(2)

    assert {:error, crash} =
             run(ctx, %{"action" => "request", "file" => "src/main.c", "query" => "fake/crash"})

    assert crash =~ "exited while this request was in flight"

    Enum.each(requests, fn request ->
      assert {:error, message} = Task.await(request, 2_000)
      assert message =~ "exited while this request was in flight"
    end)

    after_restart = raw_result(other, "fake/pid")
    refute after_restart == before
    assert raw_result(ctx, "fake/pid") == after_restart
  end

  defp second_session(ctx) do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    id = ctx.session_id <> "-other"

    on_exit(fn ->
      Enum.each(Client.list(id), &Client.stop(&1.pid))
      send(owner, :stop)
    end)

    %{
      ctx
      | session_id: id,
        owner: owner,
        opts: Keyword.merge(ctx.opts, session_id: id, session_pid: owner)
    }
  end

  defp raw_result(ctx, method) do
    result = run(ctx, %{"action" => "request", "file" => "src/main.c", "query" => method})
    [_header, json] = String.split(text!(result), "\n", parts: 2)
    Jason.decode!(json)
  end

  defp wait_pending(count, attempts \\ 200)
  defp wait_pending(_count, 0), do: false

  defp wait_pending(count, attempts) do
    if LemonLsp.ServerManager.status().pending_request_count == count do
      true
    else
      Process.sleep(10)
      wait_pending(count, attempts - 1)
    end
  end

  test "custom project catalog reaches the spawned process and initialization", ctx do
    File.mkdir_p!(Path.join(ctx.tmp, ".lemon"))

    File.write!(Path.join(ctx.tmp, ".lemon/config.toml"), """
    [runtime.tools.lsp]
    idle_timeout_ms = 0

    [runtime.tools.lsp.servers.custom_test]
    command = #{Jason.encode!(Path.join(ctx.tmp, "fake_lsp_server.exs"))}
    args = ["custom-argument"]
    extensions = [".custom"]
    language_id = "custom-language"
    env = { LSP_CUSTOM_TEST = "configured" }
    initialization_options = { custom = true }
    """)

    File.write!(Path.join(ctx.tmp, "src/main.custom"), "custom content\n")

    result =
      run(ctx, %{"action" => "request", "file" => "src/main.custom", "query" => "fake/config"})

    [_header, json] = String.split(text!(result), "\n", parts: 2)
    response = Jason.decode!(json)
    assert response["args"] == ["custom-argument"]
    assert response["env"] == "configured"
    assert response["options"] == %{"custom" => true}
  end

  defp fake_server_script do
    ~S"""
    #!/usr/bin/env elixir
    :io.setopts(:standard_io, encoding: :latin1, binary: true)

    defmodule Fake do
      def read do
        case headers(nil) do
          nil -> nil
          len -> :stdio |> IO.binread(len) |> JSON.decode!()
        end
      end

      defp headers(len) do
        case IO.binread(:stdio, :line) do
          line when is_binary(line) ->
            case String.trim(line) do
              "" -> len
              "Content-Length: " <> n -> headers(String.to_integer(n))
              _ -> headers(len)
            end

          _ ->
            nil
        end
      end

      def send(message) do
        body = JSON.encode!(Map.put(message, "jsonrpc", "2.0"))
        IO.binwrite(:stdio, "Content-Length: #{byte_size(body)}\r\n\r\n" <> body)
      end

      def reply(id, result), do: send(%{"id" => id, "result" => result})

      def range(line, from, to),
        do: %{"start" => %{"line" => line, "character" => from}, "end" => %{"line" => line, "character" => to}}

      def publish(uri, version) do
        send(%{
          "method" => "textDocument/publishDiagnostics",
          "params" => %{
            "uri" => uri,
            "version" => version,
            "diagnostics" => [
              %{"range" => range(0, 0, 3), "severity" => 1, "source" => "fake", "code" => "E1",
                "message" => "fake problem v#{version}"}
            ]
          }
        })
      end

      def await(id) do
        case read() do
          %{"id" => ^id} = message -> if Map.has_key?(message, "method"), do: await(id), else: message
          nil -> nil
          _other -> await(id)
        end
      end

      def loop(state) do
        case read() do
          nil -> :ok
          message -> message |> handle(state) |> loop()
        end
      end

      def handle(%{"method" => "fake/pid", "id" => id}, state) do
        reply(id, System.pid())
        state
      end

      def handle(%{"method" => "fake/hold"}, state), do: state
      def handle(%{"method" => "fake/crash"}, _state), do: System.halt(7)

      def handle(%{"method" => "fake/config", "id" => id}, state) do
        reply(id, %{"args" => System.argv(), "env" => System.get_env("LSP_CUSTOM_TEST"), "options" => state[:options]})
        state
      end

      def handle(%{"method" => "initialize", "id" => id, "params" => params}, state) do
        reply(id, %{
          "capabilities" => %{
            "workspace" => %{"fileOperations" => %{"willRename" => %{}, "didRename" => %{}}},
            "renameProvider" => %{"prepareProvider" => true},
            "codeActionProvider" => %{"resolveProvider" => true},
            "executeCommandProvider" => %{"commands" => ["fake.fix"]}
          }
        })

        Map.put(state, :options, params["initializationOptions"])
      end

      def handle(%{"method" => "textDocument/didOpen", "params" => %{"textDocument" => doc}}, state) do
        publish(doc["uri"], doc["version"])
        %{state | last_uri: doc["uri"], versions: Map.put(state.versions, doc["uri"], doc["version"])}
      end

      def handle(%{"method" => "textDocument/didChange", "params" => %{"textDocument" => doc}}, state) do
        publish(doc["uri"], doc["version"])
        %{state | versions: Map.put(state.versions, doc["uri"], doc["version"])}
      end

      def handle(%{"method" => "textDocument/definition", "id" => id, "params" => params}, state) do
        uri = params["textDocument"]["uri"]
        link = %{"targetRange" => range(0, 0, 20), "targetSelectionRange" => range(0, 13, 18)}
        # The same target under a non-canonical path must be reported once.
        alias_uri = String.replace(uri, "/src/", "/src/../src/")
        reply(id, [Map.put(link, "targetUri", uri), Map.put(link, "targetUri", alias_uri)])
        state
      end

      def handle(%{"method" => "textDocument/references", "id" => id, "params" => params}, state) do
        uri = params["textDocument"]["uri"]
        reply(id, for(i <- 0..59, do: %{"uri" => uri, "range" => range(rem(i, 2), i, i + 1)}))
        state
      end

      def handle(%{"method" => "textDocument/hover", "id" => id, "params" => %{"position" => p}}, state) do
        reply(id, %{"contents" => %{"kind" => "markdown", "value" => "**hover** at #{p["line"]}:#{p["character"]}"}})
        state
      end

      def handle(%{"method" => "textDocument/prepareRename", "id" => id, "params" => %{"position" => p}}, state) do
        reply(id, range(p["line"], p["character"], p["character"] + 5))
        state
      end

      def handle(%{"method" => "textDocument/rename", "id" => id, "params" => params}, state) do
        uri = params["textDocument"]["uri"]
        p = params["position"]
        created = String.replace(uri, "main.c", "created.c")

        reply(id, %{
          "documentChanges" => [
            %{"textDocument" => %{"uri" => uri, "version" => 1},
              "edits" => [%{"range" => range(p["line"], p["character"], p["character"] + 5), "newText" => params["newName"]}]},
            %{"kind" => "create", "uri" => created}
          ]
        })

        state
      end

      def handle(%{"method" => "textDocument/codeAction", "id" => id, "params" => params}, state) do
        uri = params["textDocument"]["uri"]
        count = length(params["context"]["diagnostics"])

        reply(id, [
          %{"title" => "Insert header", "kind" => "quickfix", "isPreferred" => true, "data" => uri},
          %{"title" => "Run fixer", "command" => "fake.fix", "arguments" => [uri]},
          %{"title" => "Partial fixer",
            "edit" => %{"changes" => %{uri => [%{"range" => range(0, 0, 0), "newText" => "// direct\n"}]}},
            "command" => %{"command" => "fake.partial", "arguments" => [uri]}},
          %{"title" => "Diagnostics in context: #{count}", "kind" => "quickfix"}
        ])

        state
      end

      def handle(%{"method" => "codeAction/resolve", "id" => id, "params" => action}, state) do
        edit = %{"changes" => %{action["data"] => [%{"range" => range(0, 0, 0), "newText" => "// header\n"}]}}
        reply(id, Map.put(action, "edit", edit))
        state
      end

      def handle(%{"method" => "workspace/executeCommand", "id" => id, "params" => params}, state) do
        [uri] = params["arguments"]
        edit = %{"changes" => %{uri => [%{"range" => range(0, 0, 0), "newText" => "// fixed\n"}]}}
        send(%{"id" => "apply-1", "method" => "workspace/applyEdit", "params" => %{"edit" => edit}})
        %{"result" => %{"applied" => true}} = await("apply-1")
        if params["command"] == "fake.partial" do
          partial = %{"documentChanges" => [
            %{"kind" => "create", "uri" => String.replace_suffix(uri, "main.c", "fixed.c")},
            %{"kind" => "create", "uri" => uri}
          ]}
          send(%{"id" => "apply-2", "method" => "workspace/applyEdit", "params" => %{"edit" => partial}})
          %{"result" => %{"applied" => false}} = await("apply-2")
        else
          same = %{"changes" => %{uri => [%{"range" => range(0, 0, 0), "newText" => "// fixed again\n"}]}}
          send(%{"id" => "apply-2", "method" => "workspace/applyEdit", "params" => %{"edit" => same}})
          %{"result" => %{"applied" => true}} = await("apply-2")
          extra = %{"documentChanges" => [%{"kind" => "create", "uri" => String.replace_suffix(uri, "main.c", "fixed.c")}]}
          send(%{"id" => "apply-3", "method" => "workspace/applyEdit", "params" => %{"edit" => extra}})
          %{"result" => %{"applied" => true}} = await("apply-3")
        end
        reply(id, nil)
        state
      end

      def handle(%{"method" => "workspace/willRenameFiles", "id" => id, "params" => %{"files" => [file]}}, state) do
        reply(id, %{"changes" => %{file["oldUri"] => [%{"range" => range(0, 0, 0), "newText" => "// renamed\n"}]}})
        state
      end

      def handle(%{"method" => "workspace/didRenameFiles", "params" => %{"files" => files}}, state) do
        Map.put(state, :renamed, files)
      end

      def handle(%{"method" => "fake/renamed", "id" => id}, state) do
        reply(id, Map.get(state, :renamed, []))
        state
      end

      def handle(%{"method" => "fake/state", "id" => id}, state) do
        reply(id, state.versions)
        state
      end

      def handle(%{"id" => id, "method" => _method}, state) do
        send(%{"id" => id, "error" => %{"code" => -32601, "message" => "Method not found"}})
        state
      end

      def handle(_message, state), do: state
    end

    Fake.loop(%{last_uri: nil, versions: %{}})
    """
  end
end
