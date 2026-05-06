defmodule CodingAgent.Evals.Harness do
  @moduledoc """
  Lightweight quality evaluation harness for coding workflows.

  The suite runs three evaluation classes:
  - deterministic contract checks
  - statistical stability checks
  - workflow scenario checks
  """

  alias AgentCore.{EventStream, Loop}
  alias AgentCore.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias CodingAgent.{PromptBuilder, ToolPolicy, ToolRegistry}
  alias CodingAgent.Tools.{MemoryTopic, ReadSkill, SearchMemory, SkillManage}
  alias CodingAgent.Tools.Task, as: TaskTool
  alias LemonSkills.Curator

  alias Ai.Types.{
    AssistantMessage,
    Cost,
    Model,
    ModelCost,
    TextContent,
    ToolCall,
    Usage,
    UserMessage
  }

  @required_builtin_tools ~w(read read_skill skill_manage memory_topic search_memory write edit patch bash grep find ls webfetch websearch todo task extensions_status)

  @type eval_result :: %{
          name: String.t(),
          status: :pass | :fail,
          details: map()
        }

  @type run_report :: %{
          summary: %{passed: non_neg_integer(), failed: non_neg_integer()},
          results: [eval_result()]
        }

  @spec run(keyword()) :: run_report()
  def run(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    iterations = Keyword.get(opts, :iterations, 25)

    results =
      [
        deterministic_contract_eval(cwd),
        statistical_stability_eval(cwd, iterations),
        read_edit_workflow_eval(cwd),
        memory_scope_contract_eval(cwd),
        memory_topic_contract_eval(cwd),
        auto_skill_prompt_contract_eval(cwd),
        skill_curator_behavior_contract_eval(cwd),
        learning_tool_trace_contract_eval(cwd),
        tool_use_claim_contract_eval(cwd),
        agent_loop_learning_trace_contract_eval(cwd),
        agent_loop_memory_trace_contract_eval(cwd),
        agent_loop_async_join_trace_contract_eval(cwd),
        agent_loop_parallel_join_trace_contract_eval(cwd)
      ] ++ live_model_results(cwd, opts)

    passed = Enum.count(results, &(&1.status == :pass))
    failed = Enum.count(results, &(&1.status == :fail))

    %{
      summary: %{passed: passed, failed: failed},
      results: results
    }
  end

  @spec deterministic_contract_eval(String.t()) :: eval_result()
  def deterministic_contract_eval(cwd) do
    names = ToolRegistry.list_tool_names(cwd, include_extensions: false)
    missing = @required_builtin_tools -- names
    duplicates = names -- Enum.uniq(names)

    if missing == [] and duplicates == [] do
      %{
        name: "deterministic_contract",
        status: :pass,
        details: %{tool_count: length(names), required: @required_builtin_tools}
      }
    else
      %{
        name: "deterministic_contract",
        status: :fail,
        details: %{missing_tools: missing, duplicate_tools: duplicates}
      }
    end
  end

  @spec statistical_stability_eval(String.t(), pos_integer()) :: eval_result()
  def statistical_stability_eval(cwd, iterations) do
    baseline = normalized_tool_names(cwd)

    mismatches =
      1..iterations
      |> Enum.reduce([], fn iteration, acc ->
        current = normalized_tool_names(cwd)

        if current == baseline do
          acc
        else
          [%{iteration: iteration, expected: baseline, got: current} | acc]
        end
      end)
      |> Enum.reverse()

    if mismatches == [] do
      %{
        name: "statistical_stability",
        status: :pass,
        details: %{iterations: iterations, baseline_size: length(baseline)}
      }
    else
      %{
        name: "statistical_stability",
        status: :fail,
        details: %{iterations: iterations, mismatches: mismatches}
      }
    end
  end

  @spec read_edit_workflow_eval(String.t()) :: eval_result()
  def read_edit_workflow_eval(cwd) do
    with {:ok, tmp_dir} <- create_tmp_dir(),
         {:ok, file_path} <- write_fixture_file(tmp_dir),
         {:ok, first_read} <- run_tool(cwd, "read", %{"path" => file_path}),
         :ok <- assert_contains(first_read, "1: alpha"),
         {:ok, _edit} <-
           run_tool(cwd, "edit", %{
             "path" => file_path,
             "old_text" => "beta",
             "new_text" => "beta-updated"
           }),
         {:ok, second_read} <- run_tool(cwd, "read", %{"path" => file_path}),
         :ok <- assert_contains(second_read, "beta-updated") do
      File.rm_rf(tmp_dir)

      %{
        name: "read_edit_workflow",
        status: :pass,
        details: %{file: file_path}
      }
    else
      {:error, reason} ->
        %{
          name: "read_edit_workflow",
          status: :fail,
          details: %{reason: format_reason(reason)}
        }
    end
  end

  @spec memory_scope_contract_eval(String.t()) :: eval_result()
  def memory_scope_contract_eval(_cwd) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_memory_scope_eval_#{System.unique_integer([:positive, :monotonic])}"
      )

    project_dir = Path.join(tmp_dir, "project")
    home_dir = Path.join(tmp_dir, "home")

    search_fn = fn query, opts ->
      scope_key = Keyword.fetch!(opts, :scope_key)
      limit = Keyword.fetch!(opts, :limit)

      [
        %{
          doc_id: "#{Path.basename(scope_key)}-doc",
          query: query,
          limit: limit,
          scope_key: scope_key
        }
      ]
    end

    format_results_fn = fn docs ->
      docs
      |> Enum.map(&Map.fetch!(&1, :doc_id))
      |> Enum.join(",")
    end

    tool =
      SearchMemory.tool(project_dir,
        workspace_dir: home_dir,
        search_fn: search_fn,
        format_results_fn: format_results_fn
      )

    result = tool.execute.("eval-search-memory", %{"query" => "deployment notes"}, nil, nil)
    text = flatten_text(result)

    cond do
      result.details[:scope] != :current ->
        contract_fail("memory_scope_contract", "expected default scope :current", result.details)

      result.details[:resolved_scopes] != [:project, :home] ->
        contract_fail("memory_scope_contract", "expected project and home scopes", result.details)

      not String.contains?(text, "project-doc") or not String.contains?(text, "home-doc") ->
        contract_fail("memory_scope_contract", "expected project and home search hits", %{
          text: text
        })

      true ->
        %{
          name: "memory_scope_contract",
          status: :pass,
          details: %{
            scope: result.details[:scope],
            resolved_scopes: result.details[:resolved_scopes]
          }
        }
    end
  rescue
    e -> contract_fail("memory_scope_contract", Exception.message(e), %{})
  end

  @spec memory_topic_contract_eval(String.t()) :: eval_result()
  def memory_topic_contract_eval(_cwd) do
    with {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        workspace_dir = Path.join(tmp_dir, "workspace")
        template_path = Path.join(workspace_dir, "memory/topics/TEMPLATE.md")
        topic_path = Path.join(workspace_dir, "memory/topics/harness-contract.md")

        File.mkdir_p!(Path.dirname(template_path))
        File.write!(template_path, "# Topic: <topic-slug>\n\ncontract-template")

        result =
          MemoryTopic.execute(
            "eval-memory-topic",
            %{"topic" => "Harness Contract"},
            nil,
            nil,
            workspace_dir
          )

        cond do
          not match?(%AgentToolResult{}, result) ->
            contract_fail("memory_topic_contract", "unexpected result", %{result: inspect(result)})

          result.details[:created] != true ->
            contract_fail("memory_topic_contract", "topic was not created", result.details)

          result.details[:path] != topic_path ->
            contract_fail("memory_topic_contract", "topic path drifted", result.details)

          not File.exists?(topic_path) ->
            contract_fail("memory_topic_contract", "topic file missing", %{path: topic_path})

          not String.contains?(File.read!(topic_path), "# Topic: harness-contract") ->
            contract_fail("memory_topic_contract", "template slug replacement failed", %{
              path: topic_path
            })

          true ->
            %{
              name: "memory_topic_contract",
              status: :pass,
              details: %{slug: result.details[:slug], path: result.details[:path]}
            }
        end
      after
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} -> contract_fail("memory_topic_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("memory_topic_contract", Exception.message(e), %{})
  end

  @spec auto_skill_prompt_contract_eval(String.t()) :: eval_result()
  def auto_skill_prompt_contract_eval(_cwd) do
    with {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        skill_dir = Path.join([tmp_dir, ".lemon", "skill", "hermes-memory"])
        skill_path = Path.join(skill_dir, "SKILL.md")
        sentinel = "FULL BODY SENTINEL MUST NOT BE IN PROMPT"

        File.mkdir_p!(skill_dir)

        File.write!(skill_path, """
        ---
        name: hermes-memory
        description: Hermes memory recall and durable profile discipline
        keywords:
          - hermes
          - memory
          - recall
        ---

        # Hermes Memory

        #{sentinel}
        """)

        prompt =
          PromptBuilder.build(tmp_dir, %{
            base_prompt: "Base.",
            context: "improve hermes memory recall and profile discipline",
            include_skills: true,
            include_commands: false,
            include_mentions: false
          })

        cond do
          not String.contains?(prompt, "<relevant-skills>") ->
            contract_fail("auto_skill_prompt_contract", "missing relevant skills block", %{
              prompt: prompt
            })

          not String.contains?(prompt, "<key>hermes-memory</key>") ->
            contract_fail("auto_skill_prompt_contract", "missing relevant skill key", %{
              prompt: prompt
            })

          not String.contains?(prompt, "Use `read_skill`") ->
            contract_fail("auto_skill_prompt_contract", "missing read_skill loading reminder", %{
              prompt: prompt
            })

          String.contains?(prompt, sentinel) ->
            contract_fail("auto_skill_prompt_contract", "full skill body leaked into prompt", %{})

          true ->
            %{
              name: "auto_skill_prompt_contract",
              status: :pass,
              details: %{skill: "hermes-memory", progressive_disclosure: true}
            }
        end
      after
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} -> contract_fail("auto_skill_prompt_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("auto_skill_prompt_contract", Exception.message(e), %{})
  end

  @spec skill_curator_behavior_contract_eval(String.t()) :: eval_result()
  def skill_curator_behavior_contract_eval(_cwd) do
    with {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        tool_opts = [
          run_id: "eval-skill-curator",
          session_key: "agent:skill-curator-eval:main",
          session_id: "agent:skill-curator-eval:main",
          agent_id: "skill-curator-eval"
        ]

        skill_tool = SkillManage.tool(tmp_dir, tool_opts)
        read_tool = ReadSkill.tool(tmp_dir, tool_opts)

        with {:ok, _} <-
               execute_tool(skill_tool, "seed-rollout-verify", %{
                 "action" => "create",
                 "name" => "kube-rollout-verify",
                 "scope" => "project",
                 "content" => narrow_skill_content("Kube Rollout Verify", "verify")
               }),
             {:ok, _} <-
               execute_tool(skill_tool, "seed-rollout-rollback", %{
                 "action" => "create",
                 "name" => "kube-rollout-rollback",
                 "scope" => "project",
                 "content" => narrow_skill_content("Kube Rollout Rollback", "rollback")
               }),
             {:ok, curator_result} <-
               Curator.run(
                 scope: :project,
                 cwd: tmp_dir,
                 now: ~U[2026-05-06 00:00:00Z],
                 interval_hours: 1
               ),
             :ok <- assert_curator_prompt(curator_result.review_prompt),
             {:ok, verify_text} <-
               execute_tool(read_tool, "read-rollout-verify", %{
                 "key" => "kube-rollout-verify",
                 "view" => "full"
               }),
             {:ok, rollback_text} <-
               execute_tool(read_tool, "read-rollout-rollback", %{
                 "key" => "kube-rollout-rollback",
                 "view" => "full"
               }),
             :ok <- assert_contains(verify_text, "kubectl rollout status"),
             :ok <- assert_contains(rollback_text, "kubectl rollout undo"),
             {:ok, _} <-
               execute_tool(skill_tool, "create-rollout-umbrella", %{
                 "action" => "create",
                 "name" => "kube-rollout-operations",
                 "scope" => "project",
                 "content" => umbrella_skill_content()
               }),
             {:ok, _} <-
               execute_tool(skill_tool, "archive-rollout-verify", %{
                 "action" => "archive",
                 "name" => "kube-rollout-verify",
                 "scope" => "project"
               }),
             {:ok, _} <-
               execute_tool(skill_tool, "archive-rollout-rollback", %{
                 "action" => "archive",
                 "name" => "kube-rollout-rollback",
                 "scope" => "project"
               }),
             :ok <- assert_archived(tmp_dir, "kube-rollout-verify"),
             :ok <- assert_archived(tmp_dir, "kube-rollout-rollback"),
             :ok <- assert_active_agent_skill(tmp_dir, "kube-rollout-operations") do
          %{
            name: "skill_curator_behavior_contract",
            status: :pass,
            details: %{
              prompt_candidates: Enum.map(curator_result.candidates, & &1.name),
              read_calls: ["kube-rollout-verify", "kube-rollout-rollback"],
              created: "kube-rollout-operations",
              archived: ["kube-rollout-verify", "kube-rollout-rollback"]
            }
          }
        else
          {:error, reason} ->
            contract_fail("skill_curator_behavior_contract", format_reason(reason), %{})
        end
      after
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} ->
        contract_fail("skill_curator_behavior_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("skill_curator_behavior_contract", Exception.message(e), %{})
  end

  @spec learning_tool_trace_contract_eval(String.t()) :: eval_result()
  def learning_tool_trace_contract_eval(_cwd) do
    with {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        project_dir = Path.join(tmp_dir, "project")
        home_dir = Path.join(tmp_dir, "home")
        File.mkdir_p!(project_dir)
        File.mkdir_p!(home_dir)

        {:ok, search_calls} = Agent.start_link(fn -> [] end)

        search_fn = fn query, opts ->
          Agent.update(search_calls, &[{query, opts} | &1])

          [
            %{
              doc_id: "prior-deployment-incident",
              title: "Prior deployment incident",
              scope_key: Keyword.fetch!(opts, :scope_key),
              query: query
            }
          ]
        end

        format_results_fn = fn docs ->
          docs
          |> Enum.map(&Map.fetch!(&1, :doc_id))
          |> Enum.join(",")
        end

        tool_opts = [
          run_id: "eval-learning-tool-trace",
          session_key: "agent:learning-tool-trace-eval:main",
          session_id: "agent:learning-tool-trace-eval:main",
          agent_id: "learning-tool-trace-eval"
        ]

        search_tool =
          SearchMemory.tool(project_dir,
            workspace_dir: home_dir,
            search_fn: search_fn,
            format_results_fn: format_results_fn
          )

        memory_tool = MemoryTopic.tool(project_dir, workspace_dir: project_dir)
        skill_tool = SkillManage.tool(project_dir, tool_opts)
        learning_prompt = PromptBuilder.build_learning_section()

        with :ok <- assert_learning_prompt(learning_prompt),
             {:ok, search_result} <-
               execute_tool_result(search_tool, "trace-search-prior-work", %{
                 "query" => "last time deployment incident handoff",
                 "scope" => "current"
               }),
             :ok <- assert_contains(flatten_text(search_result), "prior-deployment-incident"),
             :ok <- assert_learning_search(search_result, search_calls),
             {:ok, memory_result} <-
               execute_tool_result(memory_tool, "trace-create-memory-topic", %{
                 "topic" => "Deployment Incident Handoff"
               }),
             :ok <- assert_memory_topic_created(memory_result, project_dir),
             {:ok, _skill_create_result} <-
               execute_tool_result(skill_tool, "trace-create-skill", %{
                 "action" => "create",
                 "name" => "deployment-incident-handoff",
                 "scope" => "project",
                 "content" => deployment_incident_handoff_skill()
               }),
             :ok <- assert_active_agent_skill(project_dir, "deployment-incident-handoff"),
             {:ok, report_result} <-
               execute_tool_result(skill_tool, "trace-skill-report", %{
                 "action" => "report",
                 "scope" => "project"
               }),
             :ok <- assert_contains(flatten_text(report_result), "deployment-incident-handoff") do
          %{
            name: "learning_tool_trace_contract",
            status: :pass,
            details: %{
              search_calls: length(Agent.get(search_calls, & &1)),
              memory_topic: memory_result.details[:slug],
              skill: "deployment-incident-handoff",
              report_action: report_result.details[:action]
            }
          }
        else
          {:error, reason} ->
            contract_fail("learning_tool_trace_contract", format_reason(reason), %{})
        end
      after
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} ->
        contract_fail("learning_tool_trace_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("learning_tool_trace_contract", Exception.message(e), %{})
  end

  @spec tool_use_claim_contract_eval(String.t()) :: eval_result()
  def tool_use_claim_contract_eval(_cwd) do
    unbacked_claim = [
      %{role: :user, content: "Create a deployment notes file."},
      %{role: :assistant, content: "Done, I created deployment-notes.md."}
    ]

    backed_claim = [
      %{role: :user, content: "Create a deployment notes file."},
      %{
        role: :assistant,
        content: "",
        tool_calls: [%{id: "call_write", name: "write"}]
      },
      %{role: :tool_result, tool_call_id: "call_write", tool_name: "write", content: "ok"},
      %{role: :assistant, content: "Done, I created deployment-notes.md."}
    ]

    unbacked_detected? = unbacked_tool_claim?(unbacked_claim)
    backed_detected? = unbacked_tool_claim?(backed_claim)

    cond do
      not unbacked_detected? ->
        contract_fail(
          "tool_use_claim_contract",
          "unbacked completed-action claim was missed",
          %{}
        )

      backed_detected? ->
        contract_fail(
          "tool_use_claim_contract",
          "tool-backed completed-action claim was flagged",
          %{}
        )

      true ->
        %{
          name: "tool_use_claim_contract",
          status: :pass,
          details: %{
            unbacked_claim_detected: true,
            backed_claim_allowed: true
          }
        }
    end
  rescue
    e -> contract_fail("tool_use_claim_contract", Exception.message(e), %{})
  end

  @spec agent_loop_learning_trace_contract_eval(String.t()) :: eval_result()
  def agent_loop_learning_trace_contract_eval(_cwd) do
    with {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        :ok = write_project_skill(tmp_dir, "release-checklist", release_checklist_skill())

        tool_opts = [
          run_id: "eval-agent-loop-learning-trace",
          session_key: "agent:agent-loop-learning-trace-eval:main",
          session_id: "agent:agent-loop-learning-trace-eval:main",
          agent_id: "agent-loop-learning-trace-eval"
        ]

        read_tool = ReadSkill.tool(tmp_dir, tool_opts)
        skill_tool = SkillManage.tool(tmp_dir, tool_opts)

        prompt =
          PromptBuilder.build(tmp_dir, %{
            base_prompt: "Base.",
            context: "release checklist reusable hotfix workflow",
            include_skills: true,
            include_commands: false,
            include_mentions: false
          })

        responses = [
          trace_tool_response([
            trace_tool_call("read_skill", %{"key" => "release-checklist", "view" => "summary"},
              id: "call-read-skill"
            )
          ]),
          trace_tool_response([
            trace_tool_call(
              "skill_manage",
              %{
                "action" => "create",
                "name" => "release-hotfix-checklist",
                "scope" => "project",
                "content" => release_hotfix_checklist_skill()
              },
              id: "call-skill-manage"
            )
          ]),
          trace_final_response("Done.")
        ]

        context =
          AgentContext.new(
            system_prompt: prompt,
            tools: [read_tool, skill_tool]
          )

        config = %AgentLoopConfig{
          model: trace_model(),
          convert_to_llm: &trace_convert_to_llm/1,
          stream_fn: scripted_stream_fn(responses)
        }

        stream =
          Loop.agent_loop(
            [
              trace_user_message(
                "Use the release checklist and save the reusable hotfix workflow."
              )
            ],
            context,
            config,
            nil,
            nil
          )

        with {:ok, messages} <- EventStream.result(stream, 5_000),
             :ok <- assert_loop_tool_result(messages, "read_skill", "release-checklist"),
             :ok <- assert_loop_tool_result(messages, "skill_manage", "release-hotfix-checklist"),
             :ok <- assert_active_agent_skill(tmp_dir, "release-hotfix-checklist") do
          %{
            name: "agent_loop_learning_trace_contract",
            status: :pass,
            details: %{
              tool_results: trace_tool_result_names(messages),
              created: "release-hotfix-checklist"
            }
          }
        else
          {:error, reason} ->
            contract_fail("agent_loop_learning_trace_contract", format_reason(reason), %{})
        end
      after
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} ->
        contract_fail("agent_loop_learning_trace_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("agent_loop_learning_trace_contract", Exception.message(e), %{})
  end

  @spec agent_loop_memory_trace_contract_eval(String.t()) :: eval_result()
  def agent_loop_memory_trace_contract_eval(_cwd) do
    with {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        project_dir = Path.join(tmp_dir, "project")
        home_dir = Path.join(tmp_dir, "home")
        File.mkdir_p!(project_dir)
        File.mkdir_p!(home_dir)

        {:ok, search_calls} = Agent.start_link(fn -> [] end)

        search_fn = fn query, opts ->
          Agent.update(search_calls, &[{query, opts} | &1])

          [
            %{
              doc_id: "prior-release-handoff",
              title: "Prior release handoff",
              scope_key: Keyword.fetch!(opts, :scope_key),
              query: query
            }
          ]
        end

        format_results_fn = fn docs ->
          docs
          |> Enum.map(&Map.fetch!(&1, :doc_id))
          |> Enum.join(",")
        end

        search_tool =
          SearchMemory.tool(project_dir,
            workspace_dir: home_dir,
            search_fn: search_fn,
            format_results_fn: format_results_fn
          )

        prompt =
          PromptBuilder.build(project_dir, %{
            base_prompt: "Base.",
            context: "last time release handoff prior work",
            include_skills: false,
            include_commands: false,
            include_mentions: false
          })

        responses = [
          trace_tool_response([
            trace_tool_call(
              "search_memory",
              %{
                "query" => "last time release handoff",
                "scope" => "current",
                "limit" => "3"
              },
              id: "call-search-memory"
            )
          ]),
          trace_final_response("I found the prior release handoff.")
        ]

        context =
          AgentContext.new(
            system_prompt: prompt,
            tools: [search_tool]
          )

        config = %AgentLoopConfig{
          model: trace_model(),
          convert_to_llm: &trace_convert_to_llm/1,
          stream_fn: scripted_stream_fn(responses)
        }

        stream =
          Loop.agent_loop(
            [trace_user_message("What did we do last time for the release handoff?")],
            context,
            config,
            nil,
            nil
          )

        with {:ok, messages} <- EventStream.result(stream, 5_000),
             :ok <- assert_loop_tool_result(messages, "search_memory", "prior-release-handoff"),
             :ok <-
               assert_loop_tool_result_details(messages, "search_memory", fn details ->
                 details[:scope] == :current and details[:resolved_scopes] == [:project, :home]
               end),
             :ok <- assert_learning_search_calls(search_calls, 2) do
          %{
            name: "agent_loop_memory_trace_contract",
            status: :pass,
            details: %{
              tool_results: trace_tool_result_names(messages),
              search_calls: length(Agent.get(search_calls, & &1))
            }
          }
        else
          {:error, reason} ->
            contract_fail("agent_loop_memory_trace_contract", format_reason(reason), %{})
        end
      after
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} ->
        contract_fail("agent_loop_memory_trace_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("agent_loop_memory_trace_contract", Exception.message(e), %{})
  end

  @spec agent_loop_async_join_trace_contract_eval(String.t()) :: eval_result()
  def agent_loop_async_join_trace_contract_eval(_cwd) do
    with {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        clear_task_state()

        task_tool =
          TaskTool.tool(tmp_dir,
            run_override: fn _on_update, _signal ->
              %AgentToolResult{
                content: [%TextContent{text: "child task output"}],
                details: %{status: "completed"}
              }
            end,
            session_key: "agent:async-join-trace-eval:main",
            agent_id: "async-join-trace-eval",
            parent_run_id: "parent-run-async-join-trace"
          )

        context =
          AgentContext.new(
            system_prompt: "Use async task delegation, then join before finalizing.",
            tools: [task_tool]
          )

        config = %AgentLoopConfig{
          model: trace_model(),
          convert_to_llm: &trace_convert_to_llm/1,
          stream_fn: async_join_stream_fn()
        }

        stream =
          Loop.agent_loop(
            [trace_user_message("Delegate the research, then include the child result.")],
            context,
            config,
            nil,
            nil
          )

        with {:ok, messages} <- EventStream.result(stream, 5_000),
             :ok <- assert_async_task_joined(messages),
             :ok <- assert_final_after_join(messages) do
          %{
            name: "agent_loop_async_join_trace_contract",
            status: :pass,
            details: %{
              tool_results: trace_task_tool_result_actions(messages),
              joined_before_final: true
            }
          }
        else
          {:error, reason} ->
            contract_fail("agent_loop_async_join_trace_contract", format_reason(reason), %{})
        end
      after
        clear_task_state()
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} ->
        contract_fail("agent_loop_async_join_trace_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("agent_loop_async_join_trace_contract", Exception.message(e), %{})
  end

  @spec agent_loop_parallel_join_trace_contract_eval(String.t()) :: eval_result()
  def agent_loop_parallel_join_trace_contract_eval(_cwd) do
    with {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        clear_task_state()
        {:ok, output_counter} = Agent.start_link(fn -> 0 end)

        task_tool =
          TaskTool.tool(tmp_dir,
            run_override: fn _on_update, _signal ->
              output_number = Agent.get_and_update(output_counter, &{&1 + 1, &1 + 1})

              %AgentToolResult{
                content: [%TextContent{text: "child output #{output_number}"}],
                details: %{status: "completed"}
              }
            end,
            session_key: "agent:parallel-join-trace-eval:main",
            agent_id: "parallel-join-trace-eval",
            parent_run_id: "parent-run-parallel-join-trace"
          )

        context =
          AgentContext.new(
            system_prompt: "Run parallel child research, join all children, then aggregate.",
            tools: [task_tool]
          )

        config = %AgentLoopConfig{
          model: trace_model(),
          convert_to_llm: &trace_convert_to_llm/1,
          stream_fn: parallel_join_stream_fn()
        }

        stream =
          Loop.agent_loop(
            [trace_user_message("Run two child research tasks, then aggregate both results.")],
            context,
            config,
            nil,
            nil
          )

        with {:ok, messages} <- EventStream.result(stream, 5_000),
             :ok <- assert_parallel_tasks_joined(messages),
             :ok <- assert_final_contains(messages, ["child output 1", "child output 2"]) do
          %{
            name: "agent_loop_parallel_join_trace_contract",
            status: :pass,
            details: %{
              tool_results: trace_task_tool_result_actions(messages),
              joined_task_count: 2
            }
          }
        else
          {:error, reason} ->
            contract_fail("agent_loop_parallel_join_trace_contract", format_reason(reason), %{})
        end
      after
        clear_task_state()
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} ->
        contract_fail("agent_loop_parallel_join_trace_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("agent_loop_parallel_join_trace_contract", Exception.message(e), %{})
  end

  defp contract_fail(name, reason, details) do
    %{name: name, status: :fail, details: Map.merge(%{reason: reason}, details)}
  end

  defp normalized_tool_names(cwd) do
    cwd
    |> ToolRegistry.list_tool_names(include_extensions: false)
    |> Enum.sort()
  end

  defp live_model_results(cwd, opts) do
    if Keyword.get(opts, :live_model, false) do
      [
        live_model_memory_trace_contract_eval(cwd, opts),
        live_model_skill_learning_contract_eval(cwd, opts),
        live_model_skill_curator_contract_eval(cwd, opts),
        live_model_cron_block_contract_eval(cwd, opts)
      ]
    else
      []
    end
  end

  @spec live_model_memory_trace_contract_eval(String.t(), keyword()) :: eval_result()
  def live_model_memory_trace_contract_eval(_cwd, opts \\ []) do
    with {:ok, model, stream_options} <- live_model_config(opts),
         {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        project_dir = Path.join(tmp_dir, "project")
        home_dir = Path.join(tmp_dir, "home")
        File.mkdir_p!(project_dir)
        File.mkdir_p!(home_dir)

        {:ok, search_calls} = Agent.start_link(fn -> [] end)

        search_fn = fn query, opts ->
          Agent.update(search_calls, &[{query, opts} | &1])

          [
            %{
              doc_id: "prior-release-handoff",
              title: "Prior release handoff",
              content: "Last time we wrote the release handoff and tagged the smoke run.",
              scope_key: Keyword.fetch!(opts, :scope_key),
              query: query
            }
          ]
        end

        format_results_fn = fn docs ->
          docs
          |> Enum.map(fn doc ->
            "#{doc.title}: #{doc.doc_id}: #{doc.content}"
          end)
          |> Enum.join("\n")
        end

        search_tool =
          SearchMemory.tool(project_dir,
            workspace_dir: home_dir,
            search_fn: search_fn,
            format_results_fn: format_results_fn
          )

        context =
          AgentContext.new(
            system_prompt: live_memory_eval_prompt(),
            tools: [search_tool]
          )

        config = %AgentLoopConfig{
          model: model,
          convert_to_llm: &trace_convert_to_llm/1,
          stream_options: stream_options,
          max_tool_turns: 2
        }

        stream =
          Loop.agent_loop(
            [trace_user_message("What did we do last time for the release handoff?")],
            context,
            config,
            nil,
            nil
          )

        timeout_ms = Keyword.get(opts, :live_timeout_ms, 90_000)

        with {:ok, messages} <- EventStream.result(stream, timeout_ms),
             :ok <- assert_loop_tool_result(messages, "search_memory", "prior-release-handoff"),
             :ok <- assert_learning_search_calls(search_calls, 2),
             :ok <- assert_final_contains(messages, ["PRIOR_RELEASE_HANDOFF_FOUND"]) do
          %{
            name: "live_model_memory_trace_contract",
            status: :pass,
            details: %{
              provider: model.provider,
              model: model.id,
              tool_results: trace_tool_result_names(messages),
              search_calls: length(Agent.get(search_calls, & &1))
            }
          }
        else
          {:error, reason} ->
            contract_fail("live_model_memory_trace_contract", format_reason(reason), %{
              provider: model.provider,
              model: model.id,
              search_calls: length(Agent.get(search_calls, & &1))
            })
        end
      after
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} ->
        contract_fail("live_model_memory_trace_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("live_model_memory_trace_contract", Exception.message(e), %{})
  end

  @spec live_model_skill_learning_contract_eval(String.t(), keyword()) :: eval_result()
  def live_model_skill_learning_contract_eval(_cwd, opts \\ []) do
    with {:ok, model, stream_options} <- live_model_config(opts),
         {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        :ok = write_project_skill(tmp_dir, "release-checklist", release_checklist_skill())

        tool_opts = [
          run_id: "eval-live-model-skill-learning",
          session_key: "agent:live-model-skill-learning-eval:main",
          session_id: "agent:live-model-skill-learning-eval:main",
          agent_id: "live-model-skill-learning-eval"
        ]

        read_tool = ReadSkill.tool(tmp_dir, tool_opts)
        skill_tool = SkillManage.tool(tmp_dir, tool_opts)

        context =
          AgentContext.new(
            system_prompt: live_skill_learning_eval_prompt(),
            tools: [read_tool, skill_tool]
          )

        config = %AgentLoopConfig{
          model: model,
          convert_to_llm: &trace_convert_to_llm/1,
          stream_options: stream_options,
          max_tool_turns: 3
        }

        stream =
          Loop.agent_loop(
            [
              trace_user_message(
                "We repeated the release retrospective handoff again. Save the reusable workflow."
              )
            ],
            context,
            config,
            nil,
            nil
          )

        timeout_ms = Keyword.get(opts, :live_timeout_ms, 90_000)

        with {:ok, messages} <- EventStream.result(stream, timeout_ms),
             :ok <- assert_loop_tool_result(messages, "read_skill", "release-checklist"),
             :ok <-
               assert_loop_tool_result(messages, "skill_manage", "live-release-retro-capture"),
             :ok <- assert_active_agent_skill(tmp_dir, "live-release-retro-capture"),
             :ok <- assert_final_contains(messages, ["SKILL_CAPTURED_LIVE_MODEL"]) do
          %{
            name: "live_model_skill_learning_contract",
            status: :pass,
            details: %{
              provider: model.provider,
              model: model.id,
              tool_results: trace_tool_result_names(messages),
              created: "live-release-retro-capture"
            }
          }
        else
          {:error, reason} ->
            contract_fail("live_model_skill_learning_contract", format_reason(reason), %{
              provider: model.provider,
              model: model.id
            })
        end
      after
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} ->
        contract_fail("live_model_skill_learning_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("live_model_skill_learning_contract", Exception.message(e), %{})
  end

  @spec live_model_skill_curator_contract_eval(String.t(), keyword()) :: eval_result()
  def live_model_skill_curator_contract_eval(_cwd, opts \\ []) do
    with {:ok, model, stream_options} <- live_model_config(opts),
         {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        tool_opts = [
          run_id: "eval-live-model-skill-curator",
          session_key: "agent:live-model-skill-curator-eval:main",
          session_id: "agent:live-model-skill-curator-eval:main",
          agent_id: "live-model-skill-curator-eval"
        ]

        read_tool = ReadSkill.tool(tmp_dir, tool_opts)
        skill_tool = SkillManage.tool(tmp_dir, tool_opts)

        with {:ok, _} <-
               execute_tool(skill_tool, "seed-live-rollout-verify", %{
                 "action" => "create",
                 "name" => "kube-live-rollout-verify",
                 "scope" => "project",
                 "content" => narrow_skill_content("Kube Live Rollout Verify", "verify")
               }),
             {:ok, _} <-
               execute_tool(skill_tool, "seed-live-rollout-rollback", %{
                 "action" => "create",
                 "name" => "kube-live-rollout-rollback",
                 "scope" => "project",
                 "content" => narrow_skill_content("Kube Live Rollout Rollback", "rollback")
               }),
             {:ok, curator_result} <-
               Curator.run(
                 scope: :project,
                 cwd: tmp_dir,
                 now: ~U[2026-05-06 00:00:00Z],
                 interval_hours: 1
               ),
             :ok <- assert_live_curator_prompt(curator_result.review_prompt) do
          context =
            AgentContext.new(
              system_prompt: live_curator_eval_prompt(curator_result.review_prompt),
              tools: [read_tool, skill_tool]
            )

          config = %AgentLoopConfig{
            model: model,
            convert_to_llm: &trace_convert_to_llm/1,
            stream_options: live_curator_stream_options(stream_options, opts),
            max_tool_turns: 5
          }

          stream =
            Loop.agent_loop(
              [trace_user_message("Run the curator review for this candidate cluster.")],
              context,
              config,
              nil,
              nil
            )

          timeout_ms = Keyword.get(opts, :live_timeout_ms, 120_000)

          with {:ok, messages} <- EventStream.result(stream, timeout_ms),
               :ok <- assert_loop_tool_result(messages, "read_skill", "kubectl rollout status"),
               :ok <- assert_loop_tool_result(messages, "read_skill", "kubectl rollout undo"),
               :ok <-
                 assert_loop_tool_result(messages, "skill_manage", "kube-live-rollout-operations"),
               :ok <- assert_loop_tool_result(messages, "skill_manage", "archived"),
               :ok <- assert_archived(tmp_dir, "kube-live-rollout-verify"),
               :ok <- assert_archived(tmp_dir, "kube-live-rollout-rollback"),
               :ok <- assert_active_agent_skill(tmp_dir, "kube-live-rollout-operations"),
               :ok <- assert_final_contains(messages, ["SKILL_CURATOR_LIVE_MODEL_DONE"]) do
            %{
              name: "live_model_skill_curator_contract",
              status: :pass,
              details: %{
                provider: model.provider,
                model: model.id,
                tool_results: trace_tool_result_names(messages),
                prompt_candidates: Enum.map(curator_result.candidates, & &1.name),
                created: "kube-live-rollout-operations",
                archived: ["kube-live-rollout-verify", "kube-live-rollout-rollback"]
              }
            }
          else
            {:error, reason} ->
              contract_fail("live_model_skill_curator_contract", format_reason(reason), %{
                provider: model.provider,
                model: model.id,
                prompt_candidates: Enum.map(curator_result.candidates, & &1.name)
              })
          end
        else
          {:error, reason} ->
            contract_fail("live_model_skill_curator_contract", format_reason(reason), %{
              provider: model.provider,
              model: model.id
            })
        end
      after
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} ->
        contract_fail("live_model_skill_curator_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("live_model_skill_curator_contract", Exception.message(e), %{})
  end

  @spec live_model_cron_block_contract_eval(String.t(), keyword()) :: eval_result()
  def live_model_cron_block_contract_eval(_cwd, opts \\ []) do
    with {:ok, model, stream_options} <- live_model_config(opts),
         {:ok, tmp_dir} <- create_tmp_dir() do
      try do
        project_dir = Path.join(tmp_dir, "project")
        home_dir = Path.join(tmp_dir, "home")
        File.mkdir_p!(project_dir)
        File.mkdir_p!(home_dir)

        {:ok, search_calls} = Agent.start_link(fn -> [] end)

        search_fn = fn query, opts ->
          Agent.update(search_calls, &[{query, opts} | &1])

          [
            %{
              doc_id: "cron-rollup-prior-run",
              title: "Cron rollup prior run",
              content:
                "Previous scheduled run found queue depth stable and no schedule changes needed.",
              scope_key: Keyword.fetch!(opts, :scope_key),
              query: query
            }
          ]
        end

        format_results_fn = fn docs ->
          docs
          |> Enum.map(fn doc ->
            "#{doc.title}: #{doc.doc_id}: #{doc.content}"
          end)
          |> Enum.join("\n")
        end

        search_tool =
          SearchMemory.tool(project_dir,
            workspace_dir: home_dir,
            search_fn: search_fn,
            format_results_fn: format_results_fn
          )

        policy = %{blocked_tools: ["cron"]}

        tools =
          [search_tool, blocked_cron_tool()]
          |> Enum.filter(&ToolPolicy.allowed?(policy, &1.name))

        with :ok <- assert_tool_filtered(tools, "cron"),
             :ok <- assert_tool_available(tools, "search_memory") do
          context =
            AgentContext.new(
              system_prompt: live_cron_block_eval_prompt(),
              tools: tools
            )

          config = %AgentLoopConfig{
            model: model,
            convert_to_llm: &trace_convert_to_llm/1,
            stream_options: stream_options,
            max_tool_turns: 2
          }

          stream =
            Loop.agent_loop(
              [trace_user_message("Run the scheduled status rollup.")],
              context,
              config,
              nil,
              nil
            )

          timeout_ms = Keyword.get(opts, :live_timeout_ms, 90_000)

          with {:ok, messages} <- EventStream.result(stream, timeout_ms),
               :ok <- assert_loop_tool_result(messages, "search_memory", "cron-rollup-prior-run"),
               :ok <- assert_tool_not_used(messages, "cron"),
               :ok <- assert_learning_search_calls(search_calls, 1),
               :ok <- assert_final_contains(messages, ["CRON_BLOCKED_LIVE_MODEL_DONE"]) do
            %{
              name: "live_model_cron_block_contract",
              status: :pass,
              details: %{
                provider: model.provider,
                model: model.id,
                tool_results: trace_tool_result_names(messages),
                filtered_tools: ["cron"],
                search_calls: length(Agent.get(search_calls, & &1))
              }
            }
          else
            {:error, reason} ->
              contract_fail("live_model_cron_block_contract", format_reason(reason), %{
                provider: model.provider,
                model: model.id,
                search_calls: length(Agent.get(search_calls, & &1))
              })
          end
        else
          {:error, reason} ->
            contract_fail("live_model_cron_block_contract", format_reason(reason), %{
              provider: model.provider,
              model: model.id
            })
        end
      after
        File.rm_rf(tmp_dir)
      end
    else
      {:error, reason} ->
        contract_fail("live_model_cron_block_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("live_model_cron_block_contract", Exception.message(e), %{})
  end

  defp live_memory_eval_prompt do
    """
    You are running a live-model Lemon eval.

    The user is asking about prior work. You must call `search_memory` with scope `current` before answering. After the tool result arrives, answer with the exact marker PRIOR_RELEASE_HANDOFF_FOUND and summarize only what the tool result says.
    """
  end

  defp live_skill_learning_eval_prompt do
    """
    You are running a live-model Lemon skill-learning eval.

    The user describes a reusable workflow. Before answering, you must first call `read_skill` with key `release-checklist` and view `summary`. Then call `skill_manage` to create a project skill named `live-release-retro-capture`. Use action `create`, scope `project`, and content that includes YAML front matter with name `live-release-retro-capture`, description `Capture repeated release retrospective handoff steps`, and steps for reviewing changed files, running focused tests, and recording follow-up memory.

    After the skill tool result arrives, answer with the exact marker SKILL_CAPTURED_LIVE_MODEL and summarize only that the skill was captured.
    """
  end

  defp live_curator_eval_prompt(review_prompt) do
    """
    You are running a live-model Lemon skill-curator eval.

    #{review_prompt}

    For this eval, the two candidates `kube-live-rollout-verify` and `kube-live-rollout-rollback` are one reusable Kubernetes rollout cluster. Before answering, call `read_skill` with view `full` for both candidates. Then call `skill_manage` to create a project skill named `kube-live-rollout-operations` that combines rollout verification and rollback steps. Then call `skill_manage` with action `archive` for both absorbed candidate skills. Never delete skills.

    After the archive tool results arrive, answer with the exact marker SKILL_CURATOR_LIVE_MODEL_DONE and summarize only that the umbrella skill was created and the absorbed skills were archived.
    """
  end

  defp live_cron_block_eval_prompt do
    """
    You are running a live-model Lemon scheduled cron eval.

    This is already a scheduled cron task running in an isolated forked session. The scheduler forwards your concise completion summary back to the originating session.

    Use prior run memory for continuity. Before answering, call `search_memory` with scope `current` for the prior scheduled rollup. Do not create, update, remove, or recursively schedule cron jobs from this run. The cron management tool is intentionally blocked for scheduled runs.

    After the memory result arrives, answer with the exact marker CRON_BLOCKED_LIVE_MODEL_DONE and summarize only the prior run finding.
    """
  end

  defp blocked_cron_tool do
    %AgentTool{
      name: "cron",
      label: "Cron",
      description: "Manage Lemon internal cron jobs.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string"}
        },
        "required" => ["action"]
      },
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        %AgentToolResult{
          content: [
            %TextContent{type: :text, text: "CRON_TOOL_SHOULD_BE_BLOCKED"}
          ],
          details: %{blocked_eval: true}
        }
      end
    }
  end

  defp live_curator_stream_options(stream_options, opts) do
    max_tokens =
      Keyword.get(
        opts,
        :live_curator_max_tokens,
        max(stream_options.max_tokens || 0, 1024)
      )

    %{stream_options | max_tokens: max_tokens}
  end

  defp live_model_config(opts) do
    api_key = Keyword.get(opts, :live_api_key) || live_env("API_KEY")

    if is_binary(api_key) and api_key != "" do
      model = %Model{
        id: Keyword.get(opts, :live_model_id) || live_env("MODEL") || "kimi-for-coding",
        name: "Live Eval Model",
        api:
          live_atom(
            Keyword.get(opts, :live_api_type) || live_env("API_TYPE"),
            :anthropic_messages
          ),
        provider: live_atom(Keyword.get(opts, :live_provider) || live_env("PROVIDER"), :kimi),
        base_url:
          Keyword.get(opts, :live_base_url) || live_env("BASE_URL") ||
            "https://api.kimi.com/coding",
        reasoning: false,
        input: [:text],
        cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 200_000,
        max_tokens: 2_048,
        headers: %{}
      }

      stream_options = %Ai.Types.StreamOptions{
        api_key: api_key,
        temperature: 0.0,
        max_tokens: Keyword.get(opts, :live_max_tokens, 512)
      }

      {:ok, model, stream_options}
    else
      {:error, "live model eval requires LEMON_EVAL_API_KEY or INTEGRATION_API_KEY"}
    end
  end

  defp live_env(name) do
    System.get_env("LEMON_EVAL_#{name}") ||
      System.get_env("INTEGRATION_#{name}") ||
      legacy_live_env(name)
  end

  defp legacy_live_env("API_KEY"), do: System.get_env("ANTHROPIC_API_KEY")
  defp legacy_live_env(_), do: nil

  defp live_atom(nil, default), do: default
  defp live_atom(value, _default) when is_atom(value), do: value

  defp live_atom(value, default) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      default
    else
      String.to_atom(value)
    end
  end

  defp live_atom(_value, default), do: default

  defp run_tool(cwd, tool_name, params) do
    with {:ok, tool} <- ToolRegistry.get_tool(cwd, tool_name, include_extensions: false),
         {:ok, result} <-
           normalize_tool_result(tool.execute.("eval-#{tool_name}", params, nil, nil)) do
      {:ok, flatten_text(result)}
    end
  end

  defp normalize_tool_result(%AgentToolResult{} = result), do: {:ok, result}
  defp normalize_tool_result({:ok, %AgentToolResult{} = result}), do: {:ok, result}
  defp normalize_tool_result({:error, reason}), do: {:error, reason}

  defp normalize_tool_result(other) do
    {:error, "Unexpected tool result: #{inspect(other)}"}
  end

  defp execute_tool(tool, tool_call_id, params) do
    case normalize_tool_result(tool.execute.(tool_call_id, params, nil, nil)) do
      {:ok, result} -> {:ok, flatten_text(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool_result(tool, tool_call_id, params) do
    normalize_tool_result(tool.execute.(tool_call_id, params, nil, nil))
  end

  defp flatten_text(%AgentToolResult{content: content}) do
    content
    |> Enum.map(fn block ->
      case block do
        %{text: text} when is_binary(text) -> text
        _ -> ""
      end
    end)
    |> Enum.join("\n")
  end

  defp unbacked_tool_claim?(messages) when is_list(messages) do
    completed_action_claim?(final_assistant_content(messages)) and not tool_activity?(messages)
  end

  defp final_assistant_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(message_role(&1) == :assistant))
    |> message_content()
  end

  defp completed_action_claim?(text) when is_binary(text) do
    side_effect? =
      Regex.match?(
        ~r/\b(I|I've|I have)\s+(created|updated|edited|modified|wrote|written|deleted|ran|executed|committed|merged|applied|changed)\b/i,
        text
      )

    artifact? =
      Regex.match?(
        ~r/\b(file|files|doc|docs|test|tests|commit|branch|pr|code|script|config|database|migration|module|function|readme)\b|\.[a-z0-9]{1,6}\b/i,
        text
      )

    side_effect? and artifact?
  end

  defp completed_action_claim?(_), do: false

  defp tool_activity?(messages) do
    Enum.any?(messages, fn message ->
      message_role(message) == :tool_result or tool_calls(message) != []
    end)
  end

  defp message_role(%{role: role}), do: role
  defp message_role(%{"role" => "assistant"}), do: :assistant
  defp message_role(%{"role" => "tool_result"}), do: :tool_result
  defp message_role(%{"role" => "user"}), do: :user
  defp message_role(_), do: nil

  defp message_content(nil), do: ""
  defp message_content(%{content: content}), do: stringify_content(content)
  defp message_content(%{"content" => content}), do: stringify_content(content)
  defp message_content(_), do: ""

  defp stringify_content(content) when is_binary(content), do: content

  defp stringify_content(content) when is_list(content),
    do: Enum.map_join(content, "\n", &stringify_content/1)

  defp stringify_content(%{text: text}) when is_binary(text), do: text
  defp stringify_content(%{"text" => text}) when is_binary(text), do: text
  defp stringify_content(_), do: ""

  defp tool_calls(%{tool_calls: calls}) when is_list(calls), do: calls
  defp tool_calls(%{"tool_calls" => calls}) when is_list(calls), do: calls
  defp tool_calls(_), do: []

  defp assert_contains(text, expected) when is_binary(text) do
    if String.contains?(text, expected) do
      :ok
    else
      {:error, "Expected output to contain #{inspect(expected)}, got: #{inspect(text)}"}
    end
  end

  defp create_tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_eval_#{System.unique_integer([:positive, :monotonic])}"
      )

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, "Failed to create temp dir #{dir}: #{inspect(reason)}"}
    end
  end

  defp write_fixture_file(tmp_dir) do
    path = Path.join(tmp_dir, "sample.txt")

    case File.write(path, "alpha\nbeta\n") do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "Failed to write fixture file #{path}: #{inspect(reason)}"}
    end
  end

  defp write_project_skill(cwd, key, content) do
    skill_dir = Path.join([cwd, ".lemon", "skill", key])
    skill_path = Path.join(skill_dir, "SKILL.md")

    with :ok <- File.mkdir_p(skill_dir),
         :ok <- File.write(skill_path, content) do
      LemonSkills.refresh(cwd: cwd)
      :ok
    end
  end

  defp clear_task_state do
    try do
      CodingAgent.TaskStore.clear()
    catch
      _, _ -> :ok
    end

    try do
      CodingAgent.RunGraph.clear()
    catch
      _, _ -> :ok
    end
  end

  defp narrow_skill_content(name, mode) do
    command =
      case mode do
        "verify" -> "kubectl rollout status deployment/example"
        "rollback" -> "kubectl rollout undo deployment/example"
      end

    """
    ---
    name: #{name}
    description: Kubernetes rollout #{mode} workflow
    keywords:
      - kubernetes
      - rollout
      - #{mode}
    ---

    ## Usage

    Use this when a Kubernetes deployment needs rollout #{mode} handling.

    ## Steps

    1. Inspect the deployment and namespace.
    2. Run `#{command}`.
    3. Capture the result and next action.
    """
  end

  defp umbrella_skill_content do
    """
    ---
    name: Kube Rollout Operations
    description: Verify and rollback Kubernetes rollouts safely
    keywords:
      - kubernetes
      - rollout
      - verify
      - rollback
    ---

    ## Usage

    Use this when maintaining Kubernetes rollout health across verification and rollback.

    ## Verify

    Run `kubectl rollout status deployment/example` and inspect events before declaring success.

    ## Rollback

    Run `kubectl rollout undo deployment/example` only after identifying the failed revision and impact.
    """
  end

  defp deployment_incident_handoff_skill do
    """
    ---
    name: deployment-incident-handoff
    description: Capture and hand off recurring deployment incident response steps
    keywords:
      - deployment
      - incident
      - handoff
    ---

    ## Usage

    Use this when a deployment incident reveals a reusable handoff or verification workflow.

    ## Steps

    1. Search prior run memory for the last related deployment incident.
    2. Create or update a topic memory with durable decisions and command paths.
    3. Save the reusable handoff as a skill once the workflow is repeatable.
    """
  end

  defp release_checklist_skill do
    """
    ---
    name: Release Checklist
    description: Verify releases before final handoff
    keywords:
      - release
      - checklist
      - hotfix
    ---

    ## Usage

    Use this when release or hotfix work needs final verification.

    ## Steps

    1. Inspect changed files.
    2. Run focused tests.
    3. Record the release decision.
    """
  end

  defp release_hotfix_checklist_skill do
    """
    ---
    name: Release Hotfix Checklist
    description: Verify and document release hotfixes
    keywords:
      - release
      - hotfix
      - checklist
    ---

    ## Usage

    Use this when a release hotfix needs verification.

    ## Steps

    1. Inspect the changed files.
    2. Run the focused test command.
    3. Record the result and rollback note.
    """
  end

  defp assert_learning_prompt(prompt) do
    cond do
      not String.contains?(prompt, "Use `skill_manage`") ->
        {:error, "learning prompt does not mention skill_manage"}

      not String.contains?(prompt, "Use `memory_topic`") ->
        {:error, "learning prompt does not mention memory_topic"}

      not String.contains?(prompt, "Use `search_memory`") ->
        {:error, "learning prompt does not mention search_memory"}

      not String.contains?(prompt, "At the end of substantial work") ->
        {:error, "learning prompt does not include end-of-run capture trigger"}

      true ->
        :ok
    end
  end

  defp assert_learning_search(result, search_calls) do
    calls = Agent.get(search_calls, &Enum.reverse/1)

    cond do
      result.details[:scope] != :current ->
        {:error, "expected search_memory scope :current, got #{inspect(result.details)}"}

      result.details[:resolved_scopes] != [:project, :home] ->
        {:error, "expected current search to resolve project and home scopes"}

      length(calls) != 2 ->
        {:error, "expected search_memory to query project and home, got #{inspect(calls)}"}

      true ->
        :ok
    end
  end

  defp assert_memory_topic_created(result, workspace_dir) do
    expected_path =
      Path.join([workspace_dir, "memory", "topics", "deployment-incident-handoff.md"])

    cond do
      result.details[:created] != true ->
        {:error, "expected memory_topic to create a topic, got #{inspect(result.details)}"}

      result.details[:slug] != "deployment-incident-handoff" ->
        {:error, "unexpected memory topic slug #{inspect(result.details)}"}

      result.details[:path] != expected_path ->
        {:error, "unexpected memory topic path #{inspect(result.details)}"}

      not File.exists?(expected_path) ->
        {:error, "memory topic file missing at #{expected_path}"}

      true ->
        :ok
    end
  end

  defp assert_curator_prompt(prompt) do
    cond do
      not String.contains?(prompt, "Use read_skill") ->
        {:error, "curator prompt does not require read_skill"}

      not String.contains?(prompt, "skill_manage") ->
        {:error, "curator prompt does not mention skill_manage"}

      not String.contains?(prompt, "kube-rollout-verify") ->
        {:error, "curator prompt missing kube-rollout-verify"}

      not String.contains?(prompt, "kube-rollout-rollback") ->
        {:error, "curator prompt missing kube-rollout-rollback"}

      true ->
        :ok
    end
  end

  defp assert_live_curator_prompt(prompt) do
    cond do
      not String.contains?(prompt, "Use read_skill") ->
        {:error, "live curator prompt does not require read_skill"}

      not String.contains?(prompt, "skill_manage") ->
        {:error, "live curator prompt does not mention skill_manage"}

      not String.contains?(prompt, "kube-live-rollout-verify") ->
        {:error, "live curator prompt missing kube-live-rollout-verify"}

      not String.contains?(prompt, "kube-live-rollout-rollback") ->
        {:error, "live curator prompt missing kube-live-rollout-rollback"}

      true ->
        :ok
    end
  end

  defp assert_archived(cwd, key) do
    record = LemonSkills.Usage.get(key, scope: :project, cwd: cwd)

    cond do
      record["lifecycle_state"] != "archived" ->
        {:error, "expected #{key} to be archived, got #{inspect(record)}"}

      not LemonSkills.Config.skill_disabled?(key, cwd) ->
        {:error, "expected #{key} to be disabled after archive"}

      true ->
        :ok
    end
  end

  defp assert_active_agent_skill(cwd, key) do
    record = LemonSkills.Usage.get(key, scope: :project, cwd: cwd)

    cond do
      record["created_by"] != "agent" ->
        {:error, "expected #{key} to be agent-authored, got #{inspect(record)}"}

      record["lifecycle_state"] != "active" ->
        {:error, "expected #{key} to be active, got #{inspect(record)}"}

      true ->
        :ok
    end
  end

  defp assert_loop_tool_result(messages, tool_name, expected_text) do
    found? =
      Enum.any?(messages, fn
        %{role: :tool_result, tool_name: ^tool_name} = message ->
          stringify_content(message.content) |> String.contains?(expected_text)

        _ ->
          false
      end)

    if found? do
      :ok
    else
      {:error, "expected agent loop tool result for #{tool_name} containing #{expected_text}"}
    end
  end

  defp assert_tool_filtered(tools, tool_name) do
    if Enum.any?(tools, &(&1.name == tool_name)) do
      {:error, "expected #{tool_name} to be filtered from live eval tools"}
    else
      :ok
    end
  end

  defp assert_tool_available(tools, tool_name) do
    if Enum.any?(tools, &(&1.name == tool_name)) do
      :ok
    else
      {:error, "expected #{tool_name} to remain available in live eval tools"}
    end
  end

  defp assert_tool_not_used(messages, tool_name) do
    used? =
      Enum.any?(messages, fn
        %{role: :tool_result, tool_name: ^tool_name} -> true
        _ -> false
      end)

    if used? do
      {:error, "expected #{tool_name} not to be used"}
    else
      :ok
    end
  end

  defp assert_loop_tool_result_details(messages, tool_name, predicate) do
    found? =
      Enum.any?(messages, fn
        %{role: :tool_result, tool_name: ^tool_name, details: details} ->
          predicate.(details)

        _ ->
          false
      end)

    if found? do
      :ok
    else
      {:error, "expected agent loop tool result details for #{tool_name}"}
    end
  end

  defp assert_learning_search_calls(search_calls, expected_count) do
    calls = Agent.get(search_calls, &Enum.reverse/1)

    cond do
      length(calls) != expected_count ->
        {:error, "expected #{expected_count} search calls, got #{inspect(calls)}"}

      not Enum.all?(calls, fn {_query, opts} -> Keyword.get(opts, :scope) == :workspace end) ->
        {:error, "expected search calls to use workspace scopes, got #{inspect(calls)}"}

      true ->
        :ok
    end
  end

  defp assert_async_task_joined(messages) do
    task_results =
      Enum.filter(messages, &match?(%{role: :tool_result, tool_name: "task"}, &1))

    queued? =
      Enum.any?(task_results, fn message ->
        match?(%{status: "queued", task_id: task_id} when is_binary(task_id), message.details)
      end)

    joined? =
      Enum.any?(task_results, fn message ->
        message.details[:mode] == "wait_all" and
          stringify_content(message.content) |> String.contains?("child task output")
      end)

    cond do
      length(task_results) != 2 ->
        {:error, "expected queued and join task results, got #{inspect(task_results)}"}

      not queued? ->
        {:error, "expected async queued task result before join"}

      not joined? ->
        {:error, "expected join task result containing child output"}

      true ->
        :ok
    end
  end

  defp assert_final_after_join(messages) do
    final_index =
      Enum.find_index(messages, fn
        %AssistantMessage{stop_reason: :stop} -> true
        _ -> false
      end)

    join_index =
      Enum.find_index(messages, fn
        %{role: :tool_result, tool_name: "task", details: %{mode: "wait_all"}} -> true
        _ -> false
      end)

    final_text =
      messages
      |> Enum.reverse()
      |> Enum.find_value("", fn
        %AssistantMessage{stop_reason: :stop} = message -> stringify_content(message.content)
        _ -> nil
      end)

    cond do
      is_nil(join_index) ->
        {:error, "join result missing"}

      is_nil(final_index) ->
        {:error, "final answer missing"}

      join_index > final_index ->
        {:error, "final answer appeared before join result"}

      not String.contains?(final_text, "child task output") ->
        {:error, "final answer did not include joined task output"}

      true ->
        :ok
    end
  end

  defp assert_final_contains(messages, expected_texts) do
    final_text =
      messages
      |> Enum.reverse()
      |> Enum.find_value("", fn
        %AssistantMessage{stop_reason: :stop} = message -> stringify_content(message.content)
        _ -> nil
      end)

    missing = Enum.reject(expected_texts, &String.contains?(final_text, &1))

    if missing == [] do
      :ok
    else
      {:error, "final answer missing #{inspect(missing)}"}
    end
  end

  defp assert_parallel_tasks_joined(messages) do
    task_results =
      Enum.filter(messages, &match?(%{role: :tool_result, tool_name: "task"}, &1))

    queued_count =
      Enum.count(task_results, fn message ->
        match?(%{status: "queued", task_id: task_id} when is_binary(task_id), message.details)
      end)

    join_result =
      Enum.find(task_results, fn
        %{details: %{mode: "wait_all", tasks: tasks}} when is_list(tasks) -> length(tasks) == 2
        _ -> false
      end)

    join_text = if join_result, do: stringify_content(join_result.content), else: ""

    cond do
      queued_count != 2 ->
        {:error, "expected two queued task results, got #{inspect(task_results)}"}

      is_nil(join_result) ->
        {:error, "expected wait_all join result for two tasks"}

      not String.contains?(join_text, "child output 1") ->
        {:error, "join result missing child output 1"}

      not String.contains?(join_text, "child output 2") ->
        {:error, "join result missing child output 2"}

      true ->
        :ok
    end
  end

  defp trace_task_tool_result_actions(messages) do
    messages
    |> Enum.filter(&match?(%{role: :tool_result, tool_name: "task"}, &1))
    |> Enum.map(fn message ->
      cond do
        message.details[:status] == "queued" -> "run"
        message.details[:mode] == "wait_all" -> "join"
        true -> "unknown"
      end
    end)
  end

  defp trace_tool_result_names(messages) do
    messages
    |> Enum.filter(&match?(%{role: :tool_result}, &1))
    |> Enum.map(& &1.tool_name)
  end

  defp scripted_stream_fn(responses) do
    {:ok, responses_agent} = Agent.start_link(fn -> responses end)

    fn _model, _context, _options ->
      case Agent.get_and_update(responses_agent, fn
             [] -> {trace_final_response(""), []}
             [head | tail] -> {head, tail}
           end) do
        response -> {:ok, response_stream(response)}
      end
    end
  end

  defp async_join_stream_fn do
    fn _model, context, _options ->
      cond do
        task_joined?(context.messages) ->
          {:ok, response_stream(trace_final_response("Joined result: child task output"))}

        task_id = queued_task_id(context.messages) ->
          {:ok,
           response_stream(
             trace_tool_response([
               trace_tool_call(
                 "task",
                 %{"action" => "join", "task_ids" => [task_id], "mode" => "wait_all"},
                 id: "call-task-join"
               )
             ])
           )}

        true ->
          {:ok,
           response_stream(
             trace_tool_response([
               trace_tool_call(
                 "task",
                 %{
                   "action" => "run",
                   "description" => "Child research",
                   "prompt" => "Return child task output.",
                   "async" => true,
                   "auto_followup" => false
                 },
                 id: "call-task-run"
               )
             ])
           )}
      end
    end
  end

  defp parallel_join_stream_fn do
    fn _model, context, _options ->
      task_ids = queued_task_ids(context.messages)

      cond do
        task_joined?(context.messages) ->
          {:ok,
           response_stream(trace_final_response("Aggregated: child output 1; child output 2"))}

        length(task_ids) >= 2 ->
          {:ok,
           response_stream(
             trace_tool_response([
               trace_tool_call(
                 "task",
                 %{"action" => "join", "task_ids" => task_ids, "mode" => "wait_all"},
                 id: "call-task-join-all"
               )
             ])
           )}

        true ->
          next = length(task_ids) + 1

          {:ok,
           response_stream(
             trace_tool_response([
               trace_tool_call(
                 "task",
                 %{
                   "action" => "run",
                   "description" => "Child research #{next}",
                   "prompt" => "Return child output #{next}.",
                   "async" => true,
                   "auto_followup" => false
                 },
                 id: "call-task-run-#{next}"
               )
             ])
           )}
      end
    end
  end

  defp queued_task_id(messages) do
    Enum.find_value(messages, fn
      %{role: :tool_result, tool_name: "task", details: %{status: "queued", task_id: task_id}}
      when is_binary(task_id) ->
        task_id

      _ ->
        nil
    end)
  end

  defp queued_task_ids(messages) do
    Enum.flat_map(messages, fn
      %{role: :tool_result, tool_name: "task", details: %{status: "queued", task_id: task_id}}
      when is_binary(task_id) ->
        [task_id]

      _ ->
        []
    end)
  end

  defp task_joined?(messages) do
    Enum.any?(messages, fn
      %{role: :tool_result, tool_name: "task", details: %{mode: "wait_all"}} -> true
      _ -> false
    end)
  end

  defp response_stream(%AssistantMessage{} = response) do
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, response})

      response.content
      |> Enum.with_index()
      |> Enum.each(fn {content, index} ->
        case content do
          %TextContent{text: text} ->
            Ai.EventStream.push(stream, {:text_start, index, response})
            Ai.EventStream.push(stream, {:text_delta, index, text, response})
            Ai.EventStream.push(stream, {:text_end, index, response})

          %ToolCall{} = tool_call ->
            Ai.EventStream.push(stream, {:tool_call_start, index, tool_call, response})
            Ai.EventStream.push(stream, {:tool_call_end, index, tool_call, response})

          _ ->
            :ok
        end
      end)

      Ai.EventStream.push(stream, {:done, response.stop_reason, response})
      Ai.EventStream.complete(stream, response)
    end)

    stream
  end

  defp trace_user_message(text) do
    %UserMessage{role: :user, content: text, timestamp: System.system_time(:millisecond)}
  end

  defp trace_tool_response(tool_calls) do
    %AssistantMessage{
      role: :assistant,
      content: tool_calls,
      api: :mock,
      provider: :mock_provider,
      model: "mock-eval-model",
      usage: trace_usage(),
      stop_reason: :tool_use,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp trace_final_response(text) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: :mock,
      provider: :mock_provider,
      model: "mock-eval-model",
      usage: trace_usage(),
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp trace_tool_call(name, arguments, opts) do
    %ToolCall{
      type: :tool_call,
      id: Keyword.fetch!(opts, :id),
      name: name,
      arguments: arguments
    }
  end

  defp trace_model do
    %Model{
      id: "mock-eval-model",
      name: "Mock Eval Model",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://api.mock.test",
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0},
      context_window: 128_000,
      max_tokens: 4096,
      headers: %{}
    }
  end

  defp trace_usage do
    %Usage{
      input: 10,
      output: 5,
      total_tokens: 15,
      cost: %Cost{input: 0.0, output: 0.0, total: 0.0}
    }
  end

  defp trace_convert_to_llm(messages) do
    Enum.filter(messages, fn
      %{role: role} when role in [:user, :assistant, :tool_result] -> true
      _ -> false
    end)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
