defmodule CodingAgent.Extensions.ToolHooksTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Extensions.{SessionHooks, ToolHooks}
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

  describe "session lifecycle hooks" do
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
