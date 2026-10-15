defmodule CodingAgent.Tools.AstGrepTest do
  use ExUnit.Case, async: true

  alias CodingAgent.{FileReadTracker, MutationLock}
  alias CodingAgent.Tools.AstGrep
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  test "missing explicit backend gives install instructions", %{tmp_dir: cwd} do
    opts = [ast_grep_executable: Path.join(cwd, "missing-ast-grep")]
    assert {:error, message} = AstGrep.availability(opts)
    assert message =~ "brew install ast-grep"
    assert message =~ ":ast_grep_executable"

    File.write!(Path.join(cwd, "code.ts"), "call();")
    assert {:error, message} = execute(cwd, %{"action" => "search", "pattern" => "call()"}, opts)
    assert message =~ "unavailable"
  end

  test "rejects unsafe and malformed inputs before backend execution", %{tmp_dir: cwd} do
    base = %{"action" => "replace", "pattern" => "old($X)", "rewrite" => "new($X)"}
    assert {:error, message} = execute(cwd, base)
    assert message =~ "explicit paths"

    assert {:error, message} =
             execute(cwd, Map.merge(base, %{"paths" => ["."], "dry_run" => false}))

    assert message =~ "expected_matches"

    for params <- [
          %{"action" => "search", "pattern" => ""},
          %{"action" => "other", "pattern" => "x"},
          %{"action" => "search", "pattern" => "x", "paths" => [42]},
          %{"action" => "search", "pattern" => "x", "language" => 42},
          %{"action" => "search", "pattern" => "x", "max_results" => 0},
          %{"action" => "search", "pattern" => "x", "rewrite" => "y"},
          Map.merge(base, %{"paths" => ["."], "dry_run" => "false"})
        ] do
      assert {:error, _} = execute(cwd, params)
    end
  end

  test "refuses oversized scopes before backend execution and validates max_files", %{
    tmp_dir: cwd
  } do
    for n <- 1..1001, do: File.write!(Path.join(cwd, "#{n}.ts"), "oldApi(1)")
    base = %{"action" => "search", "pattern" => "oldApi($X)"}
    assert {:error, message} = execute(cwd, base)
    assert message =~ "exceeds max_files=1000"
    assert {:error, message} = execute(cwd, Map.put(base, "max_files", 2))
    assert message =~ "max_files=2"
    assert {:error, message} = execute(cwd, Map.put(base, "max_files", 0))
    assert message =~ "positive integer"
  end

  test "collects at most twenty per-file CLI errors while retaining successful matches", %{
    tmp_dir: cwd
  } do
    backend = fake_backend(cwd)
    File.write!(Path.join(cwd, "good.ts"), "oldApi(1)")
    for n <- 1..25, do: File.write!(Path.join(cwd, "bad#{n}.ts"), "broken")

    assert %AgentToolResult{details: details, content: content} =
             execute(cwd, %{"action" => "search", "pattern" => "oldApi($X)", "paths" => ["*.ts"]},
               ast_grep_executable: backend
             )

    assert details.match_count == 1
    assert length(details.parse_errors) == 20
    assert details.parse_errors_total == 25
    assert Enum.all?(details.parse_errors, &String.contains?(&1.path, "bad"))
    assert Enum.any?(content, &String.contains?(&1.text, "Skipped 25 files"))
  end

  test "spills expose a session-scoped artifact handle", %{tmp_dir: cwd} do
    backend = fake_backend(cwd)
    for name <- ["a.ts", "b.ts"], do: File.write!(Path.join(cwd, name), "oldApi(1)")

    opts = [
      ast_grep_executable: backend,
      spill_dir: cwd,
      session_id: "ast-artifact",
      context_guardrails: %{spill_dir: Path.join(cwd, "artifacts")}
    ]

    assert %AgentToolResult{
             details: %{artifact_uri: uri, full_output_path: path},
             content: [%{text: text}]
           } =
             execute(
               cwd,
               %{
                 "action" => "search",
                 "pattern" => "oldApi($X)",
                 "paths" => ["*.ts"],
                 "max_results" => 1
               },
               opts
             )

    assert uri =~ "artifact://"
    assert text =~ uri
    assert {:ok, ^path} = CodingAgent.Artifacts.resolve(uri, cwd, opts)
    assert length(String.split(File.read!(path), "\n", trim: true)) == 2
  end

  defp fake_backend(cwd) do
    path = Path.join(cwd, "fake-ast-grep")

    File.write!(path, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then printf 'ast-grep 0.1.0\\n'; exit 0; fi
    for file; do :; done
    case "$file" in
      *bad*.ts) printf 'cannot parse source\\n' >&2; exit 2 ;;
    esac
    printf '{"file":"%s","text":"oldApi(1)","language":"TypeScript","range":{"byteOffset":{"start":0,"end":9},"start":{"line":0,"column":0},"end":{"line":0,"column":9}}}\\n' "$file"
    """)

    File.chmod!(path, 0o700)
    path
  end

  # These are real CLI integration tests, not a mocked AST implementation.
  # CI without this optional backend skips them explicitly; the pure contracts
  # above always run. Set LEMON_AST_GREP_EXECUTABLE to run against a release binary.
  @backend_opts (case System.get_env("LEMON_AST_GREP_EXECUTABLE") do
                   nil -> []
                   executable -> [ast_grep_executable: executable]
                 end)

  describe "real ast-grep CLI" do
    @describetag :ast_grep

    setup %{tmp_dir: cwd} do
      if Process.whereis(MutationLock) == nil, do: start_supervised!(MutationLock)
      {:ok, opts: @backend_opts ++ [filesystem_checkpoints: false, spill_dir: cwd]}
    end

    test "matches nodes, not matching strings or comments, with inferred language", %{
      tmp_dir: cwd,
      opts: opts
    } do
      File.write!(
        Path.join(cwd, "code.ts"),
        "// oldApi(ignored)\nconst text = 'oldApi(ignored)';\noldApi(1, nested(2));\noldApi();\n"
      )

      assert %AgentToolResult{trust: :untrusted, details: details, content: [%{text: text}]} =
               execute(cwd, %{"action" => "search", "pattern" => "oldApi($$$ARGS)"}, opts)

      assert details.match_count == 2
      assert details.file_count == 1
      assert text =~ "Captures:"
      assert text =~ "nested(2)"
      refute text =~ "ignored"
      assert Enum.all?(details.matches, &(&1["language"] == "TypeScript"))
    end

    test "named capture identity avoids false positives", %{tmp_dir: cwd, opts: opts} do
      File.write!(Path.join(cwd, "code.ts"), "a && a.foo; b && c.foo;\n")

      assert %AgentToolResult{details: %{match_count: 1}} =
               execute(
                 cwd,
                 %{
                   "action" => "search",
                   "pattern" => "$X && $X.foo",
                   "language" => nil,
                   "paths" => nil,
                   "rewrite" => nil
                 },
                 opts
               )
    end

    test "preview and apply preserve captures including an empty variadic capture", %{
      tmp_dir: cwd,
      opts: opts
    } do
      path = Path.join(cwd, "code.ts")
      source = "oldApi(1, nested(2));\noldApi();\n"
      File.write!(path, source)
      params = replacement(["code.ts"])

      assert %AgentToolResult{details: %{applied: false, match_count: 2}} =
               execute(cwd, Map.put(params, "expected_matches", 0), opts)

      assert File.read!(path) == source

      assert %AgentToolResult{details: %{applied: true, match_count: 2}} =
               execute(
                 cwd,
                 Map.merge(params, %{"dry_run" => false, "expected_matches" => 2}),
                 opts
               )

      assert File.read!(path) == "newApi(1, nested(2));\nnewApi();\n"
    end

    test "count mismatch prevents every file write", %{tmp_dir: cwd, opts: opts} do
      File.write!(Path.join(cwd, "a.ts"), "oldApi(1);\n")
      File.write!(Path.join(cwd, "b.ts"), "oldApi(2);\n")
      params = Map.merge(replacement(["*.ts"]), %{"dry_run" => false, "expected_matches" => 1})
      assert {:error, message} = execute(cwd, params, opts)
      assert message =~ "Expected 1 matches but found 2"
      assert File.read!(Path.join(cwd, "a.ts")) == "oldApi(1);\n"
      assert File.read!(Path.join(cwd, "b.ts")) == "oldApi(2);\n"
    end

    test "overlapping nested matches refuse the entire replacement", %{tmp_dir: cwd, opts: opts} do
      path = Path.join(cwd, "code.ts")
      File.write!(path, "oldApi(oldApi(1));\n")
      params = Map.merge(replacement(["code.ts"]), %{"dry_run" => false, "expected_matches" => 2})
      assert {:error, message} = execute(cwd, params, opts)
      assert message =~ "Overlapping"
      assert File.read!(path) == "oldApi(oldApi(1));\n"
    end

    test "refuses undefined rewrite captures instead of silently deleting them", %{
      tmp_dir: cwd,
      opts: opts
    } do
      path = Path.join(cwd, "code.ts")
      File.write!(path, "oldApi(1);\n")
      params = replacement(["code.ts"]) |> Map.put("rewrite", "newApi($MISSING)")
      assert {:error, message} = execute(cwd, params, opts)
      assert message =~ "uncaptured"
      assert File.read!(path) == "oldApi(1);\n"
    end

    test "empty rewrite deletes only the matched node", %{tmp_dir: cwd, opts: opts} do
      path = Path.join(cwd, "code.ts")
      File.write!(path, "oldApi(1);\n")

      params =
        Map.merge(replacement(["code.ts"]), %{
          "rewrite" => "",
          "dry_run" => false,
          "expected_matches" => 1
        })

      assert %AgentToolResult{details: %{applied: true}} = execute(cwd, params, opts)
      assert File.read!(path) == ";\n"
    end

    test "display limit spills every match without limiting replacements", %{
      tmp_dir: cwd,
      opts: opts
    } do
      path = Path.join(cwd, "code.ts")
      File.write!(path, "oldApi(1);\noldApi(2);\n")

      params =
        Map.merge(replacement(["code.ts"]), %{
          "max_results" => 1,
          "dry_run" => false,
          "expected_matches" => 2
        })

      assert %AgentToolResult{
               details: %{
                 applied: true,
                 truncated: true,
                 full_output_path: spill,
                 matches: matches
               }
             } = execute(cwd, params, opts)

      assert length(matches) == 1

      records =
        spill |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert length(records) == 2
      assert Enum.all?(records, &is_binary(&1["replacement"]))
      assert File.read!(path) == "newApi(1);\nnewApi(2);\n"
    end

    test "byte-limited output keeps a retrievable complete JSONL record", %{
      tmp_dir: cwd,
      opts: opts
    } do
      File.write!(Path.join(cwd, "code.ts"), "oldApi('" <> String.duplicate("é", 1000) <> "');\n")

      assert %AgentToolResult{
               details: %{truncated: true, full_output_path: spill},
               content: [%{text: text}]
             } =
               execute(
                 cwd,
                 %{"action" => "search", "pattern" => "oldApi($X)"},
                 Keyword.put(opts, :max_bytes, 512)
               )

      assert String.valid?(text)
      assert byte_size(text) <= 512
      assert String.length(Jason.decode!(String.trim(File.read!(spill)))["text"]) > 1000
    end

    test "directory traversal skips symlinks and explicit parent symlink mutation is refused", %{
      tmp_dir: cwd,
      opts: opts
    } do
      real = Path.join(cwd, "real")
      File.mkdir!(real)
      path = Path.join(real, "code.ts")
      File.write!(path, "oldApi(1);\n")
      File.ln_s!(real, Path.join(cwd, "alias"))

      assert %AgentToolResult{details: %{match_count: 1}} =
               execute(cwd, %{"action" => "search", "pattern" => "oldApi($$$ARGS)"}, opts)

      assert {:error, message} =
               execute(
                 cwd,
                 replacement(["alias/code.ts"]),
                 Keyword.put(opts, :allow_symlinks, true)
               )

      assert message =~ "symlink"
      assert File.read!(path) == "oldApi(1);\n"
    end

    test "file symlink mutation is refused", %{tmp_dir: cwd, opts: opts} do
      path = Path.join(cwd, "code.ts")
      File.write!(path, "oldApi(1);\n")
      File.ln_s!(path, Path.join(cwd, "alias.ts"))
      assert {:error, message} = execute(cwd, replacement(["alias.ts"]), opts)
      assert message =~ "symlink"
      assert File.read!(path) == "oldApi(1);\n"
    end

    test "tracked stale contents prevent structural writes", %{tmp_dir: cwd, opts: opts} do
      if Process.whereis(FileReadTracker) == nil, do: start_supervised!(FileReadTracker)
      opts = Keyword.put(opts, :session_id, "ast-grep-#{System.unique_integer([:positive])}")
      on_exit(fn -> FileReadTracker.forget_session(opts[:session_id]) end)
      path = Path.join(cwd, "code.ts")
      File.write!(path, "oldApi(1);\n")
      FileReadTracker.record(opts, path, "oldApi(0);\n")
      assert {:error, message} = execute(cwd, replacement(["code.ts"]), opts)
      assert message =~ "Re-read"
      assert File.read!(path) == "oldApi(1);\n"
    end

    test "preview records a baseline and refuses changed bytes even when match count is unchanged",
         %{tmp_dir: cwd, opts: opts} do
      if Process.whereis(FileReadTracker) == nil, do: start_supervised!(FileReadTracker)
      opts = Keyword.put(opts, :session_id, "ast-preview-#{System.unique_integer([:positive])}")
      on_exit(fn -> FileReadTracker.forget_session(opts[:session_id]) end)
      path = Path.join(cwd, "code.ts")
      File.write!(path, "oldApi(1);\n")
      params = replacement(["code.ts"])
      assert %AgentToolResult{details: %{applied: false}} = execute(cwd, params, opts)
      File.write!(path, "oldApi(2);\n")

      assert {:error, message} =
               execute(
                 cwd,
                 Map.merge(params, %{"dry_run" => false, "expected_matches" => 1}),
                 opts
               )

      assert message =~ "Re-read"
      assert File.read!(path) == "oldApi(2);\n"
    end

    test "partial replacement failure retains its restorable checkpoint", %{
      tmp_dir: cwd,
      opts: opts
    } do
      session_id = "ast-partial-#{System.unique_integer([:positive])}"

      opts =
        Keyword.merge(opts, session_id: session_id, spill_dir: cwd, filesystem_checkpoints: true)

      on_exit(fn -> FileReadTracker.forget_session(session_id) end)

      names =
        ["a.ts"] ++
          Enum.map(1..512, &"m#{String.pad_leading(Integer.to_string(&1), 4, "0")}.ts") ++
          ["z.ts"]

      paths = Enum.map(names, &Path.join(cwd, &1))
      Enum.each(paths, &File.write!(&1, "oldApi(1);\n"))
      first = hd(paths)
      last = List.last(paths)

      # Change the final target only after a real first write, while the
      # intervening files let the watcher run before the final write check.
      watcher =
        Task.async(fn ->
          await_file_content(first, "newApi(1);\n", System.monotonic_time(:millisecond) + 5000)
          File.write!(last, "changedOutsideTool();\n")
        end)

      params =
        Map.merge(replacement(["*.ts"]), %{
          "dry_run" => false,
          "expected_matches" => length(paths),
          "max_results" => 1
        })

      result = execute(cwd, params, opts)
      assert :ok = Task.await(watcher, 5000)

      assert %AgentToolResult{
               is_error: true,
               details: %{
                 checkpoint_id: checkpoint_id,
                 applied: false,
                 partial: true,
                 written_paths: written_paths
               }
             } = result

      assert first in written_paths
      refute last in written_paths
      assert File.read!(first) == "newApi(1);\n"
      assert File.read!(last) == "changedOutsideTool();\n"
      assert hd(result.content).text =~ "Already-written paths"

      on_exit(fn -> CodingAgent.Checkpoint.delete(checkpoint_id) end)
      assert {:ok, _} = CodingAgent.Checkpoint.restore_filesystem(checkpoint_id)
      assert Enum.all?(paths, &(File.read!(&1) == "oldApi(1);\n"))
    end

    test "unsupported language returns backend error", %{tmp_dir: cwd, opts: opts} do
      File.write!(Path.join(cwd, "code.ts"), "oldApi(1);\n")

      assert {:error, message} =
               execute(
                 cwd,
                 %{
                   "action" => "search",
                   "pattern" => "oldApi($X)",
                   "language" => "not-a-language"
                 },
                 opts
               )

      assert message =~ "ast-grep exited"
    end

    test "invalid pattern is reported, not treated as no matches", %{tmp_dir: cwd, opts: opts} do
      File.write!(Path.join(cwd, "code.ts"), "oldApi(1);\n")

      assert {:error, _} =
               execute(
                 cwd,
                 %{"action" => "search", "pattern" => "a(); b();", "language" => "typescript"},
                 opts
               )
    end
  end

  defp await_file_content(path, content, deadline) do
    if File.read!(path) != content do
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("Expected structural write did not occur")

      receive do
      after
        1 -> await_file_content(path, content, deadline)
      end
    else
      :ok
    end
  end

  defp execute(cwd, params, opts \\ []), do: AstGrep.execute("ast", params, nil, nil, cwd, opts)

  defp replacement(paths) do
    %{
      "action" => "replace",
      "pattern" => "oldApi($$$ARGS)",
      "rewrite" => "newApi($$$ARGS)",
      "paths" => paths
    }
  end
end
