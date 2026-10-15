defmodule CodingAgent.Extensions.ToolHooksTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Extensions.{SessionHooks, ToolHooks}
  alias CodingAgent.Tools.Edit
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @context %{cwd: "/work", session_id: "sess-1"}

  defp tool(execute) do
    %AgentTool{
      name: "probe",
      description: "probe",
      parameters: %{},
      label: "probe",
      execute: execute
    }
  end

  defp recording_tool(test_pid, result \\ nil) do
    tool(fn _id, args, _signal, _on_update ->
      send(test_pid, {:executed, args})
      result || %AgentToolResult{content: [%TextContent{text: "ran"}], details: %{orig: true}}
    end)
  end

  defp run(tool, hooks, args \\ %{"x" => 1}) do
    ToolHooks.wrap_tool(tool, hooks, @context).execute.("call-1", args, nil, fn _ -> :ok end)
  end

  defp text(%AgentToolResult{content: content}), do: Enum.map_join(content, "", & &1.text)

  describe "on_tool_call" do
    test "first block stops the tool and later handlers, with a bounded reason" do
      test_pid = self()

      hooks = [
        on_tool_call: [
          fn %{tool_name: "probe", args: %{"x" => 1}, cwd: "/work", session_id: "sess-1"} ->
            {:block, String.duplicate("no ", 400)}
          end,
          fn _ -> send(test_pid, :later_handler_ran) end
        ]
      ]

      result = run(recording_tool(test_pid), hooks)

      assert result.is_error
      assert result.details.reason == :hook_blocked
      assert text(result) =~ "no no"
      assert String.length(result.details.hook_reason) <= 501
      refute_received {:executed, _}
      refute_received :later_handler_ran
    end

    test "argument replacement is last-wins and handlers see the model's arguments" do
      test_pid = self()

      hooks = [
        on_tool_call: [
          fn _ -> {:replace_args, %{"x" => "first"}} end,
          fn %{args: args} -> send(test_pid, {:seen, args}) end,
          fn _ -> {:replace_args, %{"x" => "last"}} end,
          fn _ -> :ok end
        ],
        on_tool_result: [fn %{args: args} -> send(test_pid, {:result_args, args}) end]
      ]

      run(recording_tool(test_pid), hooks)

      assert_received {:seen, %{"x" => 1}}
      assert_received {:executed, %{"x" => "last"}}
      assert_received {:result_args, %{"x" => "last"}}
    end

    test "a raising, throwing or exiting handler fails closed" do
      for failing <- [
            fn _ -> raise "boom #{inspect(%{"secret" => "s3cret"})}" end,
            fn _ -> throw(:nope) end,
            fn _ -> exit(:gone) end
          ] do
        result = run(recording_tool(self()), on_tool_call: [failing])

        assert result.is_error
        assert result.details.reason == :hook_blocked
        refute text(result) =~ "s3cret"
        refute_received {:executed, _}
      end
    end
  end

  describe "on_tool_result" do
    test "last replacement wins over the original, keeping trust and surviving failures" do
      original = %AgentToolResult{
        content: [%TextContent{text: "raw"}],
        details: %{orig: true},
        trust: :untrusted
      }

      hooks = [
        on_tool_result: [
          fn %{is_error: false, result: %AgentToolResult{details: %{orig: true}}} ->
            {:replace,
             %AgentToolResult{content: [%TextContent{text: "first"}], details: %{first: true}}}
          end,
          fn _ -> {:replace, %{details: %{last: true}}} end,
          fn _ -> raise "broken" end,
          fn _ -> :ok end
        ]
      ]

      assert {:ok, result} = run(recording_tool(self(), {:ok, original}), hooks)

      assert text(result) == "raw"
      assert result.details == %{last: true}
      assert result.trust == :untrusted
      refute result.is_error
    end

    test "content-only and nil-details replacements retain the complete original details" do
      original = %AgentToolResult{
        content: [%TextContent{text: "written"}],
        details: %{checkpoint_id: "before-write", path: "/work/file", display: "original"}
      }

      for replacement <- [
            %AgentToolResult{content: [%TextContent{text: "Saved."}]},
            %{content: [%TextContent{text: "Saved."}]},
            %{content: [%TextContent{text: "Saved."}], details: nil}
          ] do
        result =
          run(recording_tool(self(), original),
            on_tool_result: [fn _ -> {:replace, replacement} end]
          )

        assert text(result) == "Saved."
        assert result.details == original.details
      end
    end

    test "custom details preserve chronological receipts and path provenance in either key form" do
      receipts = %{
        checkpoint_id: "first",
        checkpoint_ids: ["first", "second"],
        checkpoint_kind: "filesystem",
        path: "/work/file",
        paths: ["/work/file"],
        changed: ["/work/file"],
        changed_files: ["file"],
        changed_paths: ["/work/file"],
        affected_paths: ["/work/file"],
        written_paths: ["/work/file"],
        partial: true,
        partial_error: true,
        success: false,
        applied: false,
        action: "replace",
        acp_client: false,
        oldText: "before",
        newText: "after",
        old_text: "before",
        new_text: "after",
        resolvedPath: "/work/file",
        perFileResults: [%{path: "/work/file", oldText: "before", newText: "after"}],
        snapshot: "native-snapshot"
      }

      for original_receipts <- [
            receipts,
            Map.delete(receipts, :checkpoint_id),
            Map.new(receipts, fn {key, value} -> {Atom.to_string(key), value} end)
          ] do
        original = %AgentToolResult{
          content: [%TextContent{text: "written"}],
          details: Map.put(original_receipts, :display, "original"),
          trust: :untrusted
        }

        forged =
          Enum.reduce(Map.keys(receipts), %{display: "custom"}, fn key, acc ->
            acc |> Map.put(key, "forged") |> Map.put(Atom.to_string(key), "forged")
          end)

        result =
          run(recording_tool(self(), original),
            on_tool_result: [
              fn _ -> {:replace, %{details: %{display: "earlier"}}} end,
              fn _ ->
                {:replace, %{content: [%TextContent{text: "Saved."}], details: forged}}
              end
            ]
          )

        assert result.details == Map.put(original_receipts, :display, "custom")
        assert text(result) == "Saved."
        assert result.trust == :untrusted
        refute result.is_error
      end
    end

    test "a hook cannot manufacture receipts or affected paths absent from the actual result" do
      for details <- [nil, %{display: "original"}, %{"checkpoint_id" => "real"}] do
        original = %AgentToolResult{content: [%TextContent{text: "ran"}], details: details}

        result =
          run(recording_tool(self(), original),
            on_tool_result: [
              fn _ ->
                {:replace,
                 %{
                   details: %{
                     "checkpoint_id" => "invented",
                     "written_paths" => ["/unrelated"],
                     checkpoint_id: "invented",
                     checkpoint_ids: ["invented"],
                     changed: ["/unrelated"],
                     partial_error: false,
                     display: "custom"
                   }
                 }}
              end
            ]
          )

        expected =
          if is_map(details),
            do: Map.merge(%{display: "custom"}, Map.take(details, ["checkpoint_id"])),
            else: %{display: "custom"}

        assert result.details == expected
      end
    end

    @tag :tmp_dir
    test "an actual large edit keeps its omitted ACP diff text and aliases absent", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "large.txt")
      File.write!(path, String.duplicate("a", 20_000) <> "\nneedle\n")
      aliases = [:oldText, :newText, :old_text, :new_text, :resolvedPath]

      forged =
        Enum.reduce(aliases, %{display: "custom"}, fn key, acc ->
          acc |> Map.put(key, "forged") |> Map.put(Atom.to_string(key), "forged")
        end)

      hooks = [on_tool_result: [fn _ -> {:replace, %{details: forged}} end]]
      edit = ToolHooks.wrap_tool(Edit.tool(tmp_dir), hooks, %{cwd: tmp_dir, session_id: "s"})
      arguments = %{"path" => path, "old_text" => "needle", "new_text" => "pin"}
      result = edit.execute.("edit", arguments, nil, fn _ -> :ok end)

      refute result.is_error
      assert File.read!(path) == String.duplicate("a", 20_000) <> "\npin\n"
      assert File.read!(result.details.path) == File.read!(path)
      assert result.details.display == "custom"

      for key <- aliases ++ Enum.map(aliases, &Atom.to_string/1) do
        refute Map.has_key?(result.details, key)
      end
    end

    test "non-map display details cannot discard a mutation receipt" do
      original = %AgentToolResult{
        content: [%TextContent{text: "written"}],
        details: %{checkpoint_id: "original", changed: ["/work/file"]}
      }

      result =
        run(recording_tool(self(), original),
          on_tool_result: [fn _ -> {:replace, %{details: "display"}} end]
        )

      assert result.details == original.details
    end

    test "partial error receipts and aborted calls cannot be hidden by replacements" do
      original = %AgentToolResult{
        content: [%TextContent{text: "partially written"}],
        details: %{
          changed_files: ["file"],
          applied: true,
          success: false,
          checkpoint_ids: ["first", "second"],
          partial_error: true,
          partial: true,
          written_paths: ["/work/file"]
        },
        is_error: true
      }

      test_pid = self()

      hooks = [
        on_tool_result: [
          fn event ->
            send(test_pid, {:error_observed, event.result, event.is_error})
            {:replace, %AgentToolResult{content: [%TextContent{text: "success"}], details: %{}}}
          end
        ]
      ]

      assert ^original = run(recording_tool(self(), original), hooks)
      assert_received {:error_observed, ^original, true}
      assert {:ok, ^original} = run(recording_tool(self(), {:ok, original}), hooks)
      assert_received {:error_observed, ^original, true}
      assert {:error, :aborted} = run(tool(fn _, _, _, _ -> {:error, :aborted} end), hooks)
      assert_received {:error_observed, %AgentToolResult{is_error: true}, true}
    end

    test "tool errors are observed with is_error and the original error is preserved" do
      test_pid = self()

      hooks = [
        on_tool_result: [
          fn %{is_error: is_error, result: result} ->
            send(test_pid, {:observed, is_error, text(result)})
            {:replace, %{content: [%TextContent{text: "masked"}]}}
          end
        ]
      ]

      error_result = %AgentToolResult{content: [%TextContent{text: "denied"}], is_error: true}
      assert ^error_result = run(recording_tool(test_pid, error_result), hooks)
      assert_received {:observed, true, "denied"}

      assert {:error, :enoent} = run(tool(fn _, _, _, _ -> {:error, :enoent} end), hooks)
      assert_received {:observed, true, ":enoent"}

      assert_raise RuntimeError, "tool crashed", fn ->
        run(tool(fn _, _, _, _ -> raise "tool crashed" end), hooks)
      end

      assert_received {:observed, true, "tool crashed"}
    end
  end

  describe "additional context" do
    test "call and result handlers append context in order after replacement, preserving receipts" do
      original = %AgentToolResult{
        content: [%TextContent{text: "raw"}],
        details: %{checkpoint_id: "real", path: "/work/file"},
        trust: :untrusted
      }

      hooks = [
        on_tool_call: [
          fn _ -> {:additional_context, "call one"} end,
          fn _ -> %{replace_args: %{"x" => 2}, additional_context: "call two"} end
        ],
        on_tool_result: [
          fn _ -> {:additional_context, "result one"} end,
          fn _ -> {:replace, %{content: [%TextContent{text: "display"}]}} end,
          fn _ -> {:additional_context, "result two"} end
        ]
      ]

      assert {:ok, result} = run(recording_tool(self(), {:ok, original}), hooks)
      assert_received {:executed, %{"x" => 2}}

      assert result.content == [
               %TextContent{text: "display"},
               %TextContent{text: "[hook context]\ncall one\ncall two\nresult one\nresult two"}
             ]

      assert result.details == original.details
      assert result.trust == :untrusted
      refute result.is_error
    end

    test "call-only context is appended without result hooks" do
      result =
        run(recording_tool(self()),
          on_tool_call: [fn _ -> {:additional_context, "call context"} end]
        )

      assert text(result) == "ran[hook context]\ncall context"
    end

    test "context shares one bounded Unicode budget across both hook events" do
      result =
        run(recording_tool(self()),
          on_tool_call: [fn _ -> {:additional_context, String.duplicate("é", 3_000)} end],
          on_tool_result: [
            fn _ -> {:additional_context, String.duplicate("界", 3_000)} end,
            fn _ -> {:additional_context, "not included"} end
          ]
        )

      assert [_, %TextContent{text: "[hook context]\n" <> context}] = result.content
      assert String.valid?(context)
      assert String.length(context) == 4_000
      assert String.starts_with?(context, String.duplicate("é", 3_000) <> "\n界")
      assert String.ends_with?(context, "…")
      refute context =~ "not included"
    end

    test "invalid, empty and unsafe context is ignored or sanitized" do
      result =
        run(recording_tool(self()),
          on_tool_call:
            Enum.map([<<255>>, nil, %{}, " \n ", "  safe\0\e text  "], fn value ->
              fn _ -> {:additional_context, value} end
            end)
        )

      assert text(result) == "ran[hook context]\nsafe text"
    end

    test "blocked calls include preceding and blocking-handler context and still short-circuit" do
      test_pid = self()

      result =
        run(recording_tool(test_pid),
          on_tool_call: [
            fn _ -> {:additional_context, "first"} end,
            fn _ -> %{block: "denied", additional_context: "why"} end,
            fn _ -> send(test_pid, :later) end
          ],
          on_tool_result: [fn _ -> send(test_pid, :result_hook) end]
        )

      assert result.is_error
      assert result.details.reason == :hook_blocked
      assert text(result) =~ "[hook context]\nfirst\nwhy"
      refute_received {:executed, _}
      refute_received :later
      refute_received :result_hook
    end

    test "failing call handlers drop their context and fail closed, retaining earlier context" do
      for fail <- [
            fn context -> raise context end,
            fn context -> throw({:additional_context, context}) end,
            fn context -> exit({:additional_context, context}) end
          ] do
        result =
          run(recording_tool(self()),
            on_tool_call: [
              fn _ -> {:additional_context, "kept"} end,
              fn _ -> fail.("discarded") end
            ]
          )

        assert result.is_error
        assert text(result) =~ "[hook context]\nkept"
        refute text(result) =~ "discarded"
        refute_received {:executed, _}
      end
    end

    test "failing result handlers drop their context and fail open" do
      result =
        run(recording_tool(self()),
          on_tool_result: [
            fn _ -> {:additional_context, "first"} end,
            fn _ -> throw({:additional_context, "discarded"}) end,
            fn _ -> exit({:additional_context, "discarded"}) end,
            fn _ -> raise "discarded" end,
            fn _ -> {:additional_context, "last"} end
          ]
        )

      refute result.is_error
      assert text(result) == "ran[hook context]\nfirst\nlast"
    end

    test "structured tool errors retain status, trust and receipts while gaining context" do
      original = %AgentToolResult{
        content: [%TextContent{text: "partial failure"}],
        is_error: true,
        trust: :untrusted,
        details: %{partial: true, checkpoint_id: "receipt", written_paths: ["/work/file"]}
      }

      for outcome <- [original, {:ok, original}] do
        result =
          run(recording_tool(self(), outcome),
            on_tool_call: [fn _ -> {:additional_context, "call"} end],
            on_tool_result: [
              fn _ -> {:replace, %{content: [%TextContent{text: "hidden"}]}} end,
              fn %{is_error: true} -> {:additional_context, "result"} end
            ]
          )

        result = if is_tuple(result), do: elem(result, 1), else: result
        assert result.is_error
        assert result.trust == original.trust
        assert result.details == original.details
        assert text(result) == "partial failure[hook context]\ncall\nresult"
      end
    end

    test "non-result errors and raised tools retain their original contracts" do
      hooks = [
        on_tool_call: [fn _ -> {:additional_context, "call"} end],
        on_tool_result: [fn _ -> {:additional_context, "result"} end]
      ]

      assert {:error, :aborted} = run(tool(fn _, _, _, _ -> {:error, :aborted} end), hooks)

      assert_raise RuntimeError, "tool crashed", fn ->
        run(tool(fn _, _, _, _ -> raise "tool crashed" end), hooks)
      end
    end
  end

  describe "session lifecycle hooks" do
    test "start context is ordered, bounded and excludes failed handlers" do
      hooks = [
        on_session_start: [
          fn _ -> {:additional_context, "first\0"} end,
          fn _ -> throw({:additional_context, "discarded"}) end,
          fn _ -> {:additional_context, "second"} end,
          fn _ -> {:additional_context, String.duplicate("é", 5_000)} end
        ],
        on_session_shutdown: [fn _ -> {:additional_context, "ignored"} end]
      ]

      assert {:additional_context, context} = SessionHooks.session_start(hooks, %{})
      assert String.starts_with?(context, "first\nsecond\né")
      assert String.length(context) == 4_000
      refute context =~ "discarded"
      assert :ok = SessionHooks.session_shutdown(hooks, %{})
    end

    test "isolate failures and stop waiting for a hung handler" do
      test_pid = self()

      hooks = [
        on_session_start: [
          fn _ -> raise "broken" end,
          fn event -> send(test_pid, {:started, event}) end,
          fn _ ->
            send(test_pid, {:hung, self()})
            Process.sleep(:infinity)
          end
        ]
      ]

      event = %{session_id: "s", cwd: "/w", session_scope: :main}
      assert :ok = SessionHooks.session_start(hooks, event, timeout_ms: 100)

      assert_received {:started, ^event}
      assert_received {:hung, hung}
      ref = Process.monitor(hung)
      assert_receive {:DOWN, ^ref, :process, ^hung, _}
    end
  end
end
