defmodule CodingAgent.ToolDisclosureTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodingAgent.ToolDisclosure
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  # ==========================================================================
  # Fixtures
  # ==========================================================================

  defp tool(name, opts \\ []) do
    %AgentTool{
      name: name,
      description: Keyword.get(opts, :description, "Tool #{name}"),
      label: Keyword.get(opts, :label, name),
      parameters:
        Keyword.get(opts, :parameters, %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        }),
      execute:
        Keyword.get(opts, :execute, fn _id, _params, _signal, _on_update ->
          %AgentToolResult{content: [%TextContent{text: "ran #{name}"}]}
        end)
    }
  end

  defp tuple(name, source, opts \\ []), do: {name, tool(name, opts), source}

  # Padding to make a tool's schema cost predictable and large.
  defp fat(name, source, bytes) do
    tuple(name, source, description: String.duplicate("x", bytes))
  end

  defp tiny_budget, do: %{enabled: true, budget_tokens: 1, catalog_tokens: 2_000, max_results: 5}

  defp huge_budget,
    do: %{enabled: true, budget_tokens: 10_000_000, catalog_tokens: 2_000, max_results: 5}

  defp names(tools), do: Enum.map(tools, & &1.name)

  defp find(tools, name), do: Enum.find(tools, &(&1.name == name))

  defp text(%AgentToolResult{content: [%TextContent{text: text}]}), do: text

  # ==========================================================================
  # Budget / activation
  # ==========================================================================

  describe "apply/3 activation" do
    test "is a no-op below the budget" do
      tuples = [tuple("read", :builtin), tuple("mcp_a", {:mcp, :srv})]
      extras = [tool("extra_one")]

      %{tools: tools, report: report} = ToolDisclosure.apply(tuples, extras, huge_budget())

      assert tools == Enum.map(tuples, fn {_n, t, _s} -> t end) ++ extras
      assert report.active == false
      assert report.reason == :under_budget
      assert report.catalog_tier == :inactive
      assert report.hidden_count == 0
      assert report.hidden_names == []
      refute "tool_search" in names(tools)
      refute "tool_invoke" in names(tools)
    end

    test "is a no-op when disabled even far over budget" do
      tuples = [fat("mcp_a", {:mcp, :srv}, 50_000)]

      %{tools: tools, report: report} =
        ToolDisclosure.apply(tuples, [], %{tiny_budget() | enabled: false})

      assert names(tools) == ["mcp_a"]
      assert report.active == false
      assert report.reason == :disabled
      assert report.catalog_tier == :inactive
      assert report.estimated_tokens > 1
    end

    test "activation is strictly above the budget" do
      tuples = [fat("mcp_a", {:mcp, :srv}, 4_000)]
      estimated = ToolDisclosure.estimate_tool_tokens(elem(hd(tuples), 1))

      %{report: at_budget} =
        ToolDisclosure.apply(tuples, [], %{huge_budget() | budget_tokens: estimated})

      assert at_budget.active == false
      assert at_budget.reason == :under_budget

      %{report: over_budget} =
        ToolDisclosure.apply(tuples, [], %{huge_budget() | budget_tokens: estimated - 1})

      assert over_budget.active == true
      assert over_budget.reason == nil
    end

    test "estimate_tool_tokens matches the documented heuristic" do
      t = tool("probe", description: "a description", parameters: %{"type" => "object"})

      expected =
        LemonAi.Tokens.estimate_bytes(
          Jason.encode!(%{
            "name" => "probe",
            "description" => "a description",
            "parameters" => %{"type" => "object"}
          })
        )

      assert ToolDisclosure.estimate_tool_tokens(t) == expected
    end

    test "a non-encodable schema does not raise and still costs something" do
      t = tool("bad", description: "some description", parameters: %{"pid" => self()})

      estimate = ToolDisclosure.estimate_tool_tokens(t)
      assert is_integer(estimate)
      assert estimate > 0
    end
  end

  # ==========================================================================
  # config/2
  # ==========================================================================

  describe "config/2" do
    test "defaults when the settings manager has no tools section" do
      assert ToolDisclosure.config(%{extension_paths: []}) == ToolDisclosure.defaults()
      assert ToolDisclosure.config(nil) == ToolDisclosure.defaults()
    end

    test "settings beat defaults and the session override beats settings" do
      settings = %{tools: %{disclosure: %{budget_tokens: 100, catalog_tokens: 7}}}

      assert ToolDisclosure.config(settings).budget_tokens == 100
      assert ToolDisclosure.config(settings).catalog_tokens == 7

      assert ToolDisclosure.config(settings, budget_tokens: 50).budget_tokens == 50
      # Untouched keys still come from the settings layer.
      assert ToolDisclosure.config(settings, budget_tokens: 50).catalog_tokens == 7
    end

    test "string keys work at every level" do
      settings = %{"tools" => %{"disclosure" => %{"budget_tokens" => 100, "enabled" => false}}}

      cfg = ToolDisclosure.config(settings, %{"budget_tokens" => 33})

      assert cfg.budget_tokens == 33
      assert cfg.enabled == false
    end

    test "out-of-contract values are sanitized back to defaults" do
      logs =
        capture_log(fn ->
          cfg =
            ToolDisclosure.config(%{
              tools: %{disclosure: %{budget_tokens: 0, catalog_tokens: "nope", enabled: "yes"}}
            })

          assert cfg.budget_tokens == ToolDisclosure.defaults().budget_tokens
          assert cfg.catalog_tokens == ToolDisclosure.defaults().catalog_tokens
          assert cfg.enabled == ToolDisclosure.defaults().enabled
        end)

      assert logs =~ "ignoring invalid budget_tokens"
    end
  end

  # ==========================================================================
  # Partition & determinism
  # ==========================================================================

  describe "apply/3 partition" do
    setup do
      tuples = [
        fat("read", :builtin, 3_000),
        tuple("bash", :builtin),
        tuple("mcp_srv_one", {:mcp, :srv}),
        tuple("ext_tool", {:extension, SomeExtension}),
        tuple("wasm_tool", {:wasm, %{name: "wasm_tool", path: "/tmp/w.wasm"}})
      ]

      extras = [tool("extra_one")]

      %{tuples: tuples, extras: extras}
    end

    test "builtins and extras stay disclosed; the long tail is hidden", ctx do
      %{tools: tools, report: report} =
        ToolDisclosure.apply(ctx.tuples, ctx.extras, tiny_budget())

      assert names(tools) == ["read", "bash", "extra_one", "tool_search", "tool_invoke"]

      assert report.active == true
      assert report.total_tools == 6
      assert report.disclosed_count == 3
      assert report.hidden_count == 3
      assert report.hidden_names == ["ext_tool", "mcp_srv_one", "wasm_tool"]
    end

    test "the same input produces a byte-identical tool array", ctx do
      a = ToolDisclosure.apply(ctx.tuples, ctx.extras, tiny_budget())
      b = ToolDisclosure.apply(ctx.tuples, ctx.extras, tiny_budget())

      assert names(a.tools) == names(b.tools)

      assert Enum.map(a.tools, & &1.description) == Enum.map(b.tools, & &1.description)
      assert Enum.map(a.tools, & &1.parameters) == Enum.map(b.tools, & &1.parameters)
      assert a.report == b.report
    end

    test "a tool claiming a bridge name is dropped, not hidden" do
      tuples = [
        fat("read", :builtin, 3_000),
        tuple("tool_invoke", {:mcp, :srv})
      ]

      {result, logs} =
        with_log(fn -> ToolDisclosure.apply(tuples, [], tiny_budget()) end)

      assert logs =~ "collides with a bridge tool name"
      assert result.report.shadowed_by_bridge == ["tool_invoke"]
      assert result.report.hidden_names == []
      assert names(result.tools) == ["read", "tool_search", "tool_invoke"]

      invoke = find(result.tools, "tool_invoke")

      assert {:error, message} =
               invoke.execute.("id", %{"name" => "tool_invoke", "args" => %{}}, nil, nil)

      assert message =~ "cannot be invoked through tool_invoke"
    end
  end

  # ==========================================================================
  # Catalog tiers
  # ==========================================================================

  describe "catalog tiers" do
    test "inline_descriptions lists each hidden tool's first description line" do
      tuples = [
        fat("read", :builtin, 3_000),
        tuple("mcp_alpha", {:mcp, :srv}, description: "Alpha does things\nmore detail here"),
        tuple("mcp_beta", {:mcp, :srv}, description: "Beta does other things")
      ]

      %{tools: tools, report: report} = ToolDisclosure.apply(tuples, [], tiny_budget())

      assert report.catalog_tier == :inline_descriptions

      description = find(tools, "tool_search").description
      assert description =~ "- mcp_alpha: Alpha does things"
      assert description =~ "- mcp_beta: Beta does other things"
      refute description =~ "more detail here"
    end

    test "a tiny catalog budget falls back to names, then to search-only" do
      tuples =
        [fat("read", :builtin, 3_000)] ++
          Enum.map(1..30, fn i -> tuple("mcp_tool_#{i}", {:mcp, :srv}) end)

      %{tools: names_tools, report: names_report} =
        ToolDisclosure.apply(tuples, [], %{tiny_budget() | catalog_tokens: 100})

      assert names_report.catalog_tier == :inline_names
      names_description = find(names_tools, "tool_search").description
      assert names_description =~ "Deferred tool names: mcp_tool_1,"
      refute names_description =~ "- mcp_tool_1:"

      %{tools: search_tools, report: search_report} =
        ToolDisclosure.apply(tuples, [], %{tiny_budget() | catalog_tokens: 1})

      assert search_report.catalog_tier == :search_only
      search_description = find(search_tools, "tool_search").description
      assert search_description =~ "too large to list"
      refute search_description =~ "mcp_tool_1"
    end
  end

  # ==========================================================================
  # tool_search
  # ==========================================================================

  describe "tool_search execute" do
    setup do
      tuples = [
        fat("read", :builtin, 3_000),
        tuple("mcp_github_issue", {:mcp, :github},
          description: "Create a GitHub issue",
          parameters: %{
            "type" => "object",
            "properties" => %{"title" => %{"type" => "string"}},
            "required" => ["title"]
          }
        ),
        tuple("mcp_notes", {:mcp, :notes}, description: "Search github notes"),
        tuple("mcp_zebra", {:mcp, :zoo}, description: "Nothing to do with anything")
      ]

      %{tools: tools} = ToolDisclosure.apply(tuples, [], tiny_budget())
      %{search: find(tools, "tool_search")}
    end

    test "free text matches names and descriptions, name matches ranking higher", %{
      search: search
    } do
      result = search.execute.("id", %{"query" => "github"}, nil, nil)

      # mcp_github_issue scores 2 (name contains) + 1 (description contains);
      # mcp_notes scores 1 (description only).
      assert result.details.matched == ["mcp_github_issue", "mcp_notes"]

      body = text(result)
      assert body =~ "## mcp_github_issue"
      assert body =~ "Source: mcp:github"
      assert body =~ "Create a GitHub issue"
      assert body =~ ~s("title")
    end

    test "ties break by name ascending", %{search: search} do
      tuples = [
        fat("read", :builtin, 3_000),
        tuple("beta_thing", {:mcp, :srv}, description: "shared keyword"),
        tuple("alpha_thing", {:mcp, :srv}, description: "shared keyword")
      ]

      %{tools: tools} = ToolDisclosure.apply(tuples, [], tiny_budget())
      result = find(tools, "tool_search").execute.("id", %{"query" => "shared"}, nil, nil)

      assert result.details.matched == ["alpha_thing", "beta_thing"]
      # The fixture search tool is unused here but keeps the setup honest.
      assert search.name == "tool_search"
    end

    test "disclosed tools are not returned for free-text queries", %{search: search} do
      result = search.execute.("id", %{"query" => "read"}, nil, nil)

      refute "read" in result.details.matched
      assert text(result) =~ "No deferred tools matched"
    end

    test "select: returns exact schemas and reports unknown names", %{search: search} do
      result =
        search.execute.("id", %{"query" => "select:mcp_notes,mcp_zebra,nope"}, nil, nil)

      assert result.details.matched == ["mcp_notes", "mcp_zebra"]
      body = text(result)
      assert body =~ "## mcp_notes"
      assert body =~ "## mcp_zebra"
      assert body =~ "Not found: nope"
    end

    test "select: also works for disclosed tools", %{search: search} do
      result = search.execute.("id", %{"query" => "select:read"}, nil, nil)

      assert result.details.matched == ["read"]
      assert text(result) =~ "Source: builtin"
    end

    test "limit is clamped to 1..20", %{search: search} do
      tuples =
        [fat("read", :builtin, 3_000)] ++
          Enum.map(1..30, fn i -> tuple("mcp_tool_#{i}", {:mcp, :srv}, description: "widget") end)

      %{tools: tools} = ToolDisclosure.apply(tuples, [], tiny_budget())
      big = find(tools, "tool_search")

      assert length(
               big.execute.("id", %{"query" => "widget", "limit" => 999}, nil, nil).details.matched
             ) ==
               20

      assert length(
               big.execute.("id", %{"query" => "widget", "limit" => 0}, nil, nil).details.matched
             ) ==
               1

      assert search.name == "tool_search"
    end

    test "missing query and abort are surfaced", %{search: search} do
      assert search.execute.("id", %{}, nil, nil) ==
               {:error, "Missing required parameter: query"}

      assert search.execute.("id", %{"query" => "  "}, nil, nil) ==
               {:error, "Missing required parameter: query"}

      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      assert search.execute.("id", %{"query" => "github"}, signal, nil) ==
               {:error, "Operation aborted"}
    end

    test "no matches names the query and the hidden count", %{search: search} do
      body = text(search.execute.("id", %{"query" => "quokka"}, nil, nil))

      assert body =~ ~s(No deferred tools matched "quokka")
      assert body =~ "3 tools are hidden"
    end
  end

  # ==========================================================================
  # tool_invoke
  # ==========================================================================

  describe "tool_invoke execute" do
    setup do
      parent = self()

      probe =
        tuple("mcp_probe", {:mcp, :srv},
          parameters: %{
            "type" => "object",
            "properties" => %{
              "count" => %{"type" => "integer"},
              "mode" => %{"type" => "string", "enum" => ["fast", "slow"]},
              "maybe" => %{"type" => ["string", "null"]},
              "payload" => %{"type" => "object"}
            },
            "required" => ["count"]
          },
          execute: fn id, params, signal, on_update ->
            send(parent, {:probe_called, id, params, signal, on_update})

            %AgentToolResult{
              content: [%TextContent{text: "probe ran"}],
              details: %{echo: params},
              trust: :untrusted
            }
          end
        )

      tuples = [fat("read", :builtin, 3_000), probe]
      %{tools: tools} = ToolDisclosure.apply(tuples, [], tiny_budget())

      %{invoke: find(tools, "tool_invoke")}
    end

    test "happy path forwards every argument and returns the result verbatim", %{invoke: invoke} do
      signal = AbortSignal.new()
      on_update = fn _ -> :ok end

      result =
        invoke.execute.(
          "call-1",
          %{"name" => "mcp_probe", "args" => %{"count" => 3}},
          signal,
          on_update
        )

      assert_received {:probe_called, "call-1", %{"count" => 3}, ^signal, ^on_update}

      assert %AgentToolResult{trust: :untrusted, details: %{echo: %{"count" => 3}}} = result
      assert text(result) == "probe ran"
    end

    test "{:ok, _} and {:error, _} pass through unchanged" do
      ok_tool =
        tuple("mcp_ok", {:mcp, :srv},
          execute: fn _, _, _, _ -> {:ok, %AgentToolResult{content: []}} end
        )

      err_tool =
        tuple("mcp_err", {:mcp, :srv}, execute: fn _, _, _, _ -> {:error, "boom"} end)

      %{tools: tools} =
        ToolDisclosure.apply([fat("read", :builtin, 3_000), ok_tool, err_tool], [], tiny_budget())

      invoke = find(tools, "tool_invoke")

      assert {:ok, %AgentToolResult{}} =
               invoke.execute.("id", %{"name" => "mcp_ok", "args" => %{}}, nil, nil)

      assert {:error, "boom"} =
               invoke.execute.("id", %{"name" => "mcp_err", "args" => %{}}, nil, nil)
    end

    test "unknown names point at tool_search and suggest close matches", %{invoke: invoke} do
      assert {:error, message} =
               invoke.execute.("id", %{"name" => "probe", "args" => %{}}, nil, nil)

      assert message =~ "Unknown tool 'probe'"
      assert message =~ "Closest matches: mcp_probe"
      assert message =~ "Use tool_search"

      assert {:error, bare} =
               invoke.execute.("id", %{"name" => "zzzz", "args" => %{}}, nil, nil)

      assert bare =~ "Unknown tool 'zzzz'"
      refute bare =~ "Closest matches"
    end

    test "the bridge tools cannot invoke themselves", %{invoke: invoke} do
      for name <- ["tool_search", "tool_invoke"] do
        assert {:error, message} =
                 invoke.execute.("id", %{"name" => name, "args" => %{}}, nil, nil)

        assert message =~ "cannot be invoked through tool_invoke"
      end
    end

    test "missing name and non-map args are rejected", %{invoke: invoke} do
      assert invoke.execute.("id", %{"args" => %{}}, nil, nil) ==
               {:error, "Missing required parameter: name"}

      assert invoke.execute.("id", %{"name" => "mcp_probe", "args" => ["a"]}, nil, nil) ==
               {:error, "Parameter 'args' must be a JSON object"}
    end

    test "aborted signal short-circuits", %{invoke: invoke} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      assert invoke.execute.(
               "id",
               %{"name" => "mcp_probe", "args" => %{"count" => 1}},
               signal,
               nil
             ) ==
               {:error, "Operation aborted"}
    end

    test "schema violations are reported with the schema attached", %{invoke: invoke} do
      assert {:error, missing} =
               invoke.execute.("id", %{"name" => "mcp_probe", "args" => %{}}, nil, nil)

      assert missing =~ "missing required parameter: count"
      assert missing =~ "Schema:"
      assert missing =~ ~s("required")

      assert {:error, wrong_type} =
               invoke.execute.(
                 "id",
                 %{"name" => "mcp_probe", "args" => %{"count" => "three"}},
                 nil,
                 nil
               )

      assert wrong_type =~ "parameter count: expected integer, got string"

      assert {:error, wrong_object} =
               invoke.execute.(
                 "id",
                 %{"name" => "mcp_probe", "args" => %{"count" => 1, "payload" => ["a"]}},
                 nil,
                 nil
               )

      assert wrong_object =~ "parameter payload: expected object, got array"

      assert {:error, bad_enum} =
               invoke.execute.(
                 "id",
                 %{"name" => "mcp_probe", "args" => %{"count" => 1, "mode" => "medium"}},
                 nil,
                 nil
               )

      assert bad_enum =~ ~s(parameter mode: must be one of "fast", "slow")
    end

    test "union types accept null and unknown extra keys are allowed", %{invoke: invoke} do
      result =
        invoke.execute.(
          "id",
          %{"name" => "mcp_probe", "args" => %{"count" => 1, "maybe" => nil, "surprise" => 9}},
          nil,
          nil
        )

      assert %AgentToolResult{} = result
      assert_received {:probe_called, _, %{"surprise" => 9}, _, _}
    end

    test "a raising tool is contained" do
      boom =
        tuple("mcp_boom", {:mcp, :srv},
          execute: fn _, _, _, _ -> raise ArgumentError, "kaboom" end
        )

      %{tools: tools} =
        ToolDisclosure.apply([fat("read", :builtin, 3_000), boom], [], tiny_budget())

      assert {:error, message} =
               find(tools, "tool_invoke").execute.(
                 "id",
                 %{"name" => "mcp_boom", "args" => %{}},
                 nil,
                 nil
               )

      assert message =~ "Tool 'mcp_boom' crashed:"
      assert message =~ "kaboom"
    end

    test "a throwing tool is contained too" do
      thrower =
        tuple("mcp_throw", {:mcp, :srv}, execute: fn _, _, _, _ -> throw(:nope) end)

      %{tools: tools} =
        ToolDisclosure.apply([fat("read", :builtin, 3_000), thrower], [], tiny_budget())

      assert {:error, message} =
               find(tools, "tool_invoke").execute.(
                 "id",
                 %{"name" => "mcp_throw", "args" => %{}},
                 nil,
                 nil
               )

      assert message =~ "Tool 'mcp_throw' crashed:"
    end
  end

  # ==========================================================================
  # validate_args/2 unit tests
  # ==========================================================================

  describe "validate_args/2" do
    test "required keys" do
      schema = %{"type" => "object", "properties" => %{}, "required" => ["a", "b"]}

      assert ToolDisclosure.validate_args(%{"a" => 1, "b" => 2}, schema) == :ok

      assert ToolDisclosure.validate_args(%{"a" => 1}, schema) ==
               {:error, ["missing required parameter: b"]}
    end

    test "type checks per JSON type" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "s" => %{"type" => "string"},
          "i" => %{"type" => "integer"},
          "n" => %{"type" => "number"},
          "b" => %{"type" => "boolean"},
          "a" => %{"type" => "array"},
          "o" => %{"type" => "object"},
          "z" => %{"type" => "null"}
        }
      }

      assert ToolDisclosure.validate_args(
               %{
                 "s" => "x",
                 "i" => 1,
                 "n" => 1.5,
                 "b" => true,
                 "a" => [],
                 "o" => %{},
                 "z" => nil
               },
               schema
             ) == :ok

      assert {:error, problems} =
               ToolDisclosure.validate_args(%{"s" => 1, "i" => "x", "b" => "yes"}, schema)

      assert problems == [
               "parameter b: expected boolean, got string",
               "parameter i: expected integer, got string",
               "parameter s: expected string, got integer"
             ]
    end

    test "booleans are not integers or numbers" do
      schema = %{"type" => "object", "properties" => %{"i" => %{"type" => "integer"}}}

      assert {:error, ["parameter i: expected integer, got boolean"]} =
               ToolDisclosure.validate_args(%{"i" => true}, schema)
    end

    test "unknown type names are permissive" do
      schema = %{"type" => "object", "properties" => %{"x" => %{"type" => "quaternion"}}}

      assert ToolDisclosure.validate_args(%{"x" => "anything"}, schema) == :ok
    end

    test "enum membership" do
      schema = %{"type" => "object", "properties" => %{"m" => %{"enum" => ["a", "b"]}}}

      assert ToolDisclosure.validate_args(%{"m" => "a"}, schema) == :ok

      assert {:error, [problem]} = ToolDisclosure.validate_args(%{"m" => "c"}, schema)
      assert problem =~ "must be one of"
    end

    test "a schema without properties only enforces required" do
      schema = %{"type" => "object", "required" => ["a"]}

      assert ToolDisclosure.validate_args(%{"a" => %{"whatever" => 1}}, schema) == :ok

      assert {:error, ["missing required parameter: a"]} =
               ToolDisclosure.validate_args(%{}, schema)
    end

    test "a non-map schema enforces nothing" do
      assert ToolDisclosure.validate_args(%{"a" => 1}, nil) == :ok
      assert ToolDisclosure.validate_args(%{"a" => 1}, "nonsense") == :ok
    end

    test "non-map arguments are rejected" do
      assert {:error, ["arguments must be a JSON object"]} =
               ToolDisclosure.validate_args(["a"], %{"type" => "object"})
    end
  end

  # ==========================================================================
  # skipped_report/1
  # ==========================================================================

  describe "skipped_report/1" do
    test "is an inactive report carrying the reason" do
      report = ToolDisclosure.skipped_report(:custom_tools)

      assert report.active == false
      assert report.reason == :custom_tools
      assert report.hidden_count == 0
      assert report.catalog_tier == :inactive
    end
  end
end
