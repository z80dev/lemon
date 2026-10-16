defmodule CodingAgent.Tools.SemanticFindTest do
  use ExUnit.Case, async: true

  alias CodingAgent.SettingsManager
  alias CodingAgent.ToolRegistry
  alias CodingAgent.Tools.SemanticFind
  alias CodingAgent.Tools.SemanticFind.Candidates
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{AssistantMessage, Context, Cost, TextContent, Usage}
  alias LemonCore.{Store, UsageLedger, UsageStore}

  @moduletag :tmp_dir

  defp settings(section \\ %{enabled: true}, roles \\ %{"smol" => "openai:gpt-4o-mini"}),
    do: %SettingsManager{model_roles: roles, tools: %{semantic_find: section}}

  defp message(text, opts \\ []) do
    %AssistantMessage{
      content: [%TextContent{text: text}],
      provider: Keyword.get(opts, :provider, :openai),
      model: Keyword.get(opts, :model, "gpt-4o-mini"),
      stop_reason: :stop,
      usage: %Usage{
        input: Keyword.get(opts, :input, 120),
        output: Keyword.get(opts, :output, 20),
        total_tokens: Keyword.get(opts, :input, 120) + Keyword.get(opts, :output, 20),
        cost: %Cost{total: Keyword.get(opts, :cost, 0.0)}
      }
    }
  end

  defp answer(ids_and_reasons),
    do:
      Jason.encode!(%{
        "results" => for({id, reason} <- ids_and_reasons, do: %{"id" => id, "reason" => reason})
      })

  defp project(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "lib/uploader.ex"), """
    defmodule Uploader do
      def schedule_retry(upload, attempt) do
        # exponential backoff after a failed upload
        Process.send_after(self(), {:retry, upload}, backoff(attempt))
      end

      defp backoff(attempt), do: round(:math.pow(2, attempt) * 100)
    end
    """)

    File.write!(
      Path.join(dir, "lib/unrelated.ex"),
      "defmodule Other do\n  def hello, do: :world\nend\n"
    )

    dir
  end

  defp run(dir, params, opts) do
    SemanticFind.execute("call_1", params, nil, nil, dir, opts)
  end

  describe "availability" do
    test "is off unless enabled in config", %{tmp_dir: dir} do
      refute SemanticFind.available?(settings_manager: %SettingsManager{tools: %{}}, cwd: dir)
      refute SemanticFind.available?(settings_manager: settings(%{enabled: false}), cwd: dir)
      refute SemanticFind.available?(settings_manager: settings(%{enabled: "yes"}), cwd: dir)
      assert SemanticFind.available?(settings_manager: settings(), cwd: dir)

      names = fn settings ->
        dir
        |> ToolRegistry.get_tools(
          settings_manager: settings,
          include_extensions: false,
          include_mcp: false
        )
        |> Enum.map(& &1.name)
      end

      refute "semantic_find" in names.(%SettingsManager{tools: %{}})
      assert "semantic_find" in names.(settings())
      assert "find" in names.(settings())
    end

    test "needs an explicitly configured small model, never the active one", %{tmp_dir: dir} do
      no_role = settings(%{enabled: true}, %{})
      refute SemanticFind.available?(settings_manager: no_role, cwd: dir)

      assert SemanticFind.available?(
               settings_manager: settings(%{enabled: true}, %{"tiny" => "openai:gpt-4o-mini"}),
               cwd: dir
             )

      assert SemanticFind.available?(
               settings_manager: settings(%{enabled: true, model: "openai:gpt-4o-mini"}, %{}),
               cwd: dir
             )

      # "@role" selectors must name a role that is actually configured.
      refute SemanticFind.available?(
               settings_manager: settings(%{enabled: true, model: "@smol"}, %{}),
               cwd: dir
             )

      assert {:error, message} =
               run(project(dir), %{"query" => "retry failed upload"},
                 settings_manager: no_role,
                 semantic_find_complete: fn _, _, _ -> flunk("model must not be called") end
               )

      assert message =~ "explicitly configured small model"
    end

    test "explicit role chains never fall back to the main model", %{tmp_dir: dir} do
      configured = %{
        settings(%{enabled: true, model: "@tiny"}, %{"tiny" => "@smol"})
        | default_model: "openai:gpt-4o-mini"
      }

      refute SemanticFind.available?(settings_manager: configured, cwd: dir)

      refute "semantic_find" in Enum.map(
               ToolRegistry.get_tools(dir,
                 settings_manager: configured,
                 include_extensions: false,
                 include_mcp: false
               ),
               & &1.name
             )

      assert {:error, error} =
               run(project(dir), %{"query" => "retry upload"},
                 settings_manager: configured,
                 semantic_find_complete: fn _, _, _ -> flunk("no fallback call") end
               )

      assert error =~ "explicitly configured small model"
    end

    test "rejects an API without an enforced output ceiling", %{tmp_dir: dir} do
      configured = settings(%{enabled: true, model: "openai-codex:gpt-6-luna"})
      refute SemanticFind.available?(settings_manager: configured, cwd: dir)

      assert {:error, error} =
               run(project(dir), %{"query" => "retry upload"},
                 settings_manager: configured,
                 semantic_find_complete: fn _, _, _ -> flunk("uncapped API called") end
               )

      assert error =~ "enforced token ceiling"
    end

    test "a directly built tool still refuses when disabled", %{tmp_dir: dir} do
      tool =
        SemanticFind.tool(dir,
          settings_manager: settings(%{enabled: false}),
          semantic_find_complete: fn _, _, _ -> flunk("model must not be called") end
        )

      assert %AgentTool{name: "semantic_find"} = tool
      assert {:error, message} = tool.execute.("call", %{"query" => "retry"}, nil, nil)
      assert message =~ "disabled"
    end
  end

  describe "search" do
    test "ranks candidates with the configured small model and caps tokens", %{tmp_dir: dir} do
      project(dir)
      owner = self()

      complete = fn model, %Context{} = context, options ->
        send(owner, {:call, model, context, options})
        [%{content: prompt}] = context.messages
        [id] = Regex.run(~r/(\d+)\t[^\n]*schedule_retry/, prompt, capture: :all_but_first)

        {:ok,
         message(answer([{String.to_integer(id), "schedules the retry"}, {999, "invented"}]))}
      end

      assert %AgentToolResult{
               content: [%TextContent{text: text}],
               details: details,
               trust: :untrusted
             } =
               run(dir, %{"query" => "where a failed upload is retried with backoff"},
                 settings_manager: settings(),
                 semantic_find_complete: complete,
                 semantic_find_usage_record: fn _ -> :ok end
               )

      assert text =~ "lib/uploader.ex:2 - schedules the retry"
      refute text =~ "invented"
      assert details.model == "openai:gpt-4o-mini"

      assert details.matches == [
               %{path: "lib/uploader.ex", line: 2, reason: "schedules the retry"}
             ]

      assert_receive {:call, model, context, options}
      assert {model.provider, model.id} == {:openai, "gpt-4o-mini"}
      assert context.tools == []
      assert options.max_tokens <= 1_024
      assert options.reasoning == nil
      assert options.retry == [max_attempts: 1]
    end

    test "never sends more than the per-call token cap", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))

      for n <- 1..40 do
        File.write!(Path.join(dir, "lib/mod#{n}.ex"), """
        retry_upload = #{String.duplicate("!a={b};[]+9/", 30)} # #{n}
        """)
      end

      cap = 1_500
      owner = self()

      complete = fn _model,
                    %Context{system_prompt: system, messages: [%{content: prompt}]},
                    options ->
        send(owner, {:sent, system, prompt, options})
        {:ok, message(answer([]))}
      end

      assert %AgentToolResult{details: %{token_cap: ^cap, candidates_considered: considered}} =
               run(dir, %{"query" => "retry failed upload with backoff"},
                 settings_manager: settings(%{enabled: true, max_tokens: cap}),
                 semantic_find_complete: complete,
                 semantic_find_usage_record: fn _ -> :ok end
               )

      assert_receive {:sent, system, prompt, options}
      assert considered < 40
      # Byte-level tokenization cannot exceed one token per input byte; reserve
      # fixed framing separately. Punctuation-heavy source defeats the old /3
      # heuristic, even with a small cap and many matching candidates.
      assert byte_size(system) + byte_size(prompt) + 256 + options.max_tokens <= cap
    end

    test "makes no model call when the description has no keyword hits", %{tmp_dir: dir} do
      project(dir)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} =
               run(dir, %{"query" => "zzzqqq xylophone"},
                 settings_manager: settings(),
                 semantic_find_complete: fn _, _, _ -> flunk("model must not be called") end,
                 semantic_find_usage_record: fn _ -> flunk("nothing to record") end
               )

      assert text =~ "no model call"
      assert details.model_called == false
    end

    test "unreadable answers and failed calls are errors", %{tmp_dir: dir} do
      project(dir)
      opts = [settings_manager: settings(), semantic_find_usage_record: fn _ -> :ok end]
      params = %{"query" => "retry failed upload"}

      assert {:error, bad} =
               run(
                 dir,
                 params,
                 [semantic_find_complete: fn _, _, _ -> {:ok, message("sorry, no")} end] ++ opts
               )

      assert bad =~ "unreadable"

      assert {:error, failed} =
               run(
                 dir,
                 params,
                 [semantic_find_complete: fn _, _, _ -> {:error, :boom} end] ++ opts
               )

      assert failed =~ "model call failed"

      assert {:error, raised} =
               run(dir, params, [semantic_find_complete: fn _, _, _ -> raise "boom" end] ++ opts)

      assert raised =~ "model call failed"
    end

    test "validates parameters", %{tmp_dir: dir} do
      opts = [
        settings_manager: settings(),
        semantic_find_complete: fn _, _, _ -> flunk("no call") end
      ]

      assert {:error, _} = run(dir, %{"query" => "  "}, opts)
      assert {:error, _} = run(dir, %{}, opts)
      assert {:error, _} = run(dir, %{"query" => String.duplicate("a", 1_001)}, opts)
      assert {:error, _} = run(dir, %{"query" => "retry upload", "max_results" => 0}, opts)
    end
  end

  describe "usage" do
    test "records provider-reported usage and keeps an unknown price unknown", %{tmp_dir: dir} do
      project(dir)
      owner = self()

      complete = fn _, _, _ ->
        # Not in the model catalogue, zero reported cost: the price is unknown.
        {:ok, message(answer([]), provider: :mystery, model: "tiny-1", input: 300, output: 40)}
      end

      assert %AgentToolResult{details: %{usage: usage}} =
               run(dir, %{"query" => "retry failed upload"},
                 settings_manager: settings(),
                 run_id: "run-7",
                 session_key: "agent:bot:main",
                 agent_id: "bot",
                 session_id: "sess-1",
                 semantic_find_complete: complete,
                 semantic_find_usage_record: fn entry ->
                   send(owner, {:entry, entry})
                   :ok
                 end
               )

      assert_receive {:entry, entry}

      assert %{
               run_id: "run-7",
               session_key: "agent:bot:main",
               agent_id: "bot",
               provider: "mystery",
               model: "tiny-1",
               input: 300,
               output: 40,
               cost: nil,
               price_known: false
             } = entry

      assert usage.cost_usd == nil
      assert usage.price_known == false
      assert usage.recorded
      assert usage.input_tokens == 300
    end

    test "appears in the canonical usage ledger with its known cost", %{tmp_dir: dir} do
      project(dir)
      store = :"semantic_find_usage_store_#{System.unique_integer([:positive])}"
      ledger = :"semantic_find_usage_ledger_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Store,
         name: store,
         backend: LemonCore.Store.EtsBackend,
         backend_opts: [],
         cached_tables: [],
         finalize_run_hooks: []}
      )

      start_supervised!({UsageLedger, name: ledger, store: store})

      params = %{"query" => "retry failed upload"}

      opts = [
        settings_manager: settings(),
        run_id: "run-42",
        session_key: "agent:bot:main",
        session_id: "sess-1",
        semantic_find_complete: fn _, _, _ ->
          {:ok, message(answer([]), input: 200, output: 30, cost: 0.0004)}
        end,
        semantic_find_usage_record: &UsageLedger.record(ledger, &1)
      ]

      assert %AgentToolResult{details: %{usage: %{recorded: true, cost_usd: 0.0004}}} =
               run(dir, params, opts)

      # A second call with the same tool_call_id is its own billable occurrence.
      assert %AgentToolResult{} = run(dir, params, opts)

      now = System.system_time(:millisecond)

      assert {:ok, %{records: records}} =
               UsageStore.records(
                 %{"fromMs" => now - 60_000, "toMs" => now + 60_000, "runId" => "run-42"},
                 store: store
               )

      assert length(records) == 2
      assert Enum.all?(records, &(&1.provider == "openai" and &1.model == "gpt-4o-mini"))
      assert Enum.all?(records, &(&1.input_tokens == 200 and &1.output_tokens == 30))
      assert Enum.all?(records, &(&1.cost_usd == 0.0004 and &1.price_known))
      assert Enum.all?(records, &(&1.session_key == "agent:bot:main"))
    end
  end

  describe "candidates" do
    test "skip ignored, hidden, dependency and binary files", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "node_modules/pkg"))
      File.mkdir_p!(Path.join(dir, ".hidden"))
      File.write!(Path.join(dir, "node_modules/pkg/a.js"), "function retryUpload() {}")
      File.write!(Path.join(dir, ".hidden/b.js"), "function retryUpload() {}")
      File.write!(Path.join(dir, "bin.dat"), <<0, 1, 2>> <> "retryUpload")
      File.write!(Path.join(dir, ".gitignore"), "ignored.js\n")
      File.write!(Path.join(dir, "ignored.js"), "function retryUpload() {}")
      File.write!(Path.join(dir, "kept.js"), "function retryUpload() {}")

      assert {:ok, [%{path: "kept.js", line: 1}], false} =
               Candidates.collect([dir], Candidates.keywords("retry upload"), dir, 10, nil)
    end

    test "keywords split identifiers, drop stopwords and stem" do
      assert Candidates.keywords("where the failed uploads are retried") == [
               "fail",
               "upload",
               "retry"
             ]

      assert "upload" in Candidates.keywords("handleUploadError")
    end
  end
end

defmodule CodingAgent.Tools.SemanticFindRequestBoundaryTest do
  use ExUnit.Case, async: false

  alias LemonAi.{EventStream, Models}
  alias LemonAi.Providers.{Anthropic, OpenAICodexResponses, OpenAICompletions, OpenAIResponses}
  alias LemonAi.Types.{Context, StreamOptions, UserMessage}

  setup do
    defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(defaults)
      Req.Test.set_req_test_to_private(%{})
    end)
  end

  test "audited APIs send the ceiling in the HTTP request; Codex does not" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(owner, {:body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    context = Context.new(messages: [%UserMessage{content: "retry upload"}])

    for {provider, model, field} <- [
          {OpenAICompletions, Models.get_model(:openai, "gpt-4o-mini"), "max_completion_tokens"},
          {OpenAIResponses, %{Models.get_model(:openai, "gpt-4o-mini") | api: :openai_responses},
           "max_output_tokens"},
          {Anthropic, Models.get_model(:anthropic, "claude-sonnet-5"), "max_tokens"}
        ] do
      assert {:ok, stream} =
               provider.stream(model, context, %StreamOptions{api_key: "offline", max_tokens: 128})

      assert_receive {:body, body}, 5_000
      assert body[field] == 128
      EventStream.result(stream, 5_000)
    end

    jwt =
      "header." <>
        Base.encode64(
          Jason.encode!(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "offline"}})
        ) <> ".signature"

    model = Models.get_model(:"openai-codex", "gpt-6-luna")

    assert {:ok, stream} =
             OpenAICodexResponses.stream(model, context, %StreamOptions{
               api_key: jwt,
               max_tokens: 128
             })

    assert_receive {:body, body}, 5_000
    refute Map.has_key?(body, "max_output_tokens")
    refute Map.has_key?(body, "max_completion_tokens")
    refute Map.has_key?(body, "max_tokens")
    EventStream.result(stream, 5_000)
  end
end
