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
    path = Path.join(ctx.tmp, "src/main.c")
    listing = run(ctx, %{"action" => "code_actions", "file" => "src/main.c", "line" => 1})

    assert text!(listing) ==
             """
             3 code action(s):
               0: [quickfix] Insert header (preferred)
               1: [command] Run fixer
               2: [quickfix] Diagnostics in context: 1\
             """

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

    command =
      run(ctx, %{
        "action" => "code_actions",
        "file" => "src/main.c",
        "line" => 2,
        "apply" => true,
        "query" => "run fixer"
      })

    assert text!(command) =~ "Executed command: fake.fix"
    assert File.read!(path) =~ ~r/^\/\/ fixed\n\/\/ header\n/
    assert command.details.changed_files == ["src/main.c"]

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
    before = LemonLsp.ServerManager.status().active_count

    send(ctx.owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    assert LemonLsp.ServerManager.status().active_count == before - 1
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

      def handle(%{"method" => "initialize", "id" => id}, state) do
        reply(id, %{
          "capabilities" => %{
            "renameProvider" => %{"prepareProvider" => true},
            "codeActionProvider" => %{"resolveProvider" => true},
            "executeCommandProvider" => %{"commands" => ["fake.fix"]}
          }
        })

        state
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
        reply(id, nil)
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
