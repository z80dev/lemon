defmodule LemonEvals.Evals.AgentLoop do
  @moduledoc """
  Scripted `AgentCore.Loop`-driven contract evals: learning/skill-refinement
  traces, memory and workspace-memory traces, async/parallel task join
  traces, delegation-artifact traces, and the orchestrator/leaf-worker
  delegation toolset contract. Each eval drives a real agent loop against a
  scripted (non-live) model stream built with `LemonEvals.Support` trace
  helpers.
  """

  import LemonEvals.Support

  alias AgentCore.{EventStream, Loop}
  alias AgentCore.Types.{AgentContext, AgentLoopConfig, AgentToolResult}
  alias CodingAgent.{PromptBuilder, ToolPolicy, ToolRegistry}
  alias CodingAgent.Tools.{Grep, Patch, Read, ReadSkill, SkillManage}
  alias CodingAgent.Tools.Task, as: TaskTool
  alias LemonEvals.Types
  alias LemonSkills.Tools.SearchMemory
  alias Ai.Types.TextContent

  @spec agent_loop_learning_trace_contract_eval(String.t()) :: Types.eval_result()
  def agent_loop_learning_trace_contract_eval(_cwd) do
    case create_tmp_dir() do
      {:ok, tmp_dir} ->
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
               :ok <-
                 assert_loop_tool_result(messages, "skill_manage", "release-hotfix-checklist"),
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

      {:error, reason} ->
        contract_fail("agent_loop_learning_trace_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("agent_loop_learning_trace_contract", Exception.message(e), %{})
  end

  @spec agent_loop_skill_refinement_trace_contract_eval(String.t()) :: Types.eval_result()
  def agent_loop_skill_refinement_trace_contract_eval(_cwd) do
    case create_tmp_dir() do
      {:ok, tmp_dir} ->
        try do
          :ok =
            write_project_skill(
              tmp_dir,
              "release-hotfix-checklist",
              release_hotfix_checklist_skill()
            )

          tool_opts = [
            run_id: "eval-agent-loop-skill-refinement-trace",
            session_key: "agent:agent-loop-skill-refinement-trace-eval:main",
            session_id: "agent:agent-loop-skill-refinement-trace-eval:main",
            agent_id: "agent-loop-skill-refinement-trace-eval"
          ]

          read_tool = ReadSkill.tool(tmp_dir, tool_opts)
          skill_tool = SkillManage.tool(tmp_dir, tool_opts)

          prompt =
            PromptBuilder.build(tmp_dir, %{
              base_prompt: "Base.",
              context: "release hotfix checklist needs an added follow-up owner step",
              include_skills: true,
              include_commands: false,
              include_mentions: false
            })

          responses = [
            trace_tool_response([
              trace_tool_call(
                "read_skill",
                %{"key" => "release-hotfix-checklist", "view" => "full"},
                id: "call-read-existing-skill"
              )
            ]),
            trace_tool_response([
              trace_tool_call(
                "skill_manage",
                %{
                  "action" => "patch",
                  "name" => "release-hotfix-checklist",
                  "scope" => "project",
                  "old_string" => "3. Record the result and rollback note.",
                  "new_string" =>
                    "3. Record the result, rollback note, and exact follow-up owner."
                },
                id: "call-patch-existing-skill"
              )
            ]),
            trace_final_response("Skill refined.")
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
                  "We learned release hotfix handoffs must name the follow-up owner. Update the existing checklist."
                )
              ],
              context,
              config,
              nil,
              nil
            )

          skill_path =
            Path.join([tmp_dir, ".lemon", "skill", "release-hotfix-checklist", "SKILL.md"])

          with {:ok, messages} <- EventStream.result(stream, 5_000),
               :ok <- assert_loop_tool_result(messages, "read_skill", "rollback note"),
               :ok <- assert_loop_tool_result(messages, "skill_manage", "Patched"),
               :ok <- assert_contains(File.read!(skill_path), "exact follow-up owner") do
            %{
              name: "agent_loop_skill_refinement_trace_contract",
              status: :pass,
              details: %{
                tool_results: trace_tool_result_names(messages),
                updated: "release-hotfix-checklist"
              }
            }
          else
            {:error, reason} ->
              contract_fail(
                "agent_loop_skill_refinement_trace_contract",
                format_reason(reason),
                %{}
              )
          end
        after
          File.rm_rf(tmp_dir)
        end

      {:error, reason} ->
        contract_fail("agent_loop_skill_refinement_trace_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("agent_loop_skill_refinement_trace_contract", Exception.message(e), %{})
  end

  @spec agent_loop_memory_trace_contract_eval(String.t()) :: Types.eval_result()
  def agent_loop_memory_trace_contract_eval(_cwd) do
    case create_tmp_dir() do
      {:ok, tmp_dir} ->
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

      {:error, reason} ->
        contract_fail("agent_loop_memory_trace_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("agent_loop_memory_trace_contract", Exception.message(e), %{})
  end

  @spec agent_loop_workspace_memory_file_contract_eval(String.t()) :: Types.eval_result()
  def agent_loop_workspace_memory_file_contract_eval(_cwd) do
    case create_tmp_dir() do
      {:ok, tmp_dir} ->
        try do
          project_dir = Path.join(tmp_dir, "project")
          home_dir = Path.join(tmp_dir, "home")
          memory_dir = Path.join([project_dir, "memory", "topics"])
          File.mkdir_p!(memory_dir)
          File.mkdir_p!(home_dir)

          memory_path = Path.join(memory_dir, "release-handoff.md")

          File.write!(
            memory_path,
            """
            # Release Handoff

            The deployment baton lives in the workspace memory file.
            Before answering release handoff questions, inspect this note and cite the deployment baton.
            """
          )

          grep_tool = Grep.tool(project_dir)
          read_tool = Read.tool(project_dir)

          prompt =
            CodingAgent.SystemPrompt.build(project_dir, %{
              workspace_dir: home_dir,
              session_scope: :main,
              skill_context: "release handoff workspace memory"
            })

          responses = [
            trace_tool_response([
              trace_tool_call(
                "grep",
                %{
                  "pattern" => "deployment baton",
                  "path" => "memory",
                  "literal" => true,
                  "max_results" => 5
                },
                id: "call-grep-workspace-memory"
              )
            ]),
            trace_tool_response([
              trace_tool_call(
                "read",
                %{
                  "path" => "memory/topics/release-handoff.md",
                  "limit" => 20
                },
                id: "call-read-workspace-memory"
              )
            ]),
            trace_final_response("Workspace memory says to cite the deployment baton.")
          ]

          context =
            AgentContext.new(
              system_prompt: prompt,
              tools: [grep_tool, read_tool]
            )

          config = %AgentLoopConfig{
            model: trace_model(),
            convert_to_llm: &trace_convert_to_llm/1,
            stream_fn: scripted_stream_fn(responses)
          }

          stream =
            Loop.agent_loop(
              [trace_user_message("What does project memory say about release handoff?")],
              context,
              config,
              nil,
              nil
            )

          with {:ok, messages} <- EventStream.result(stream, 5_000),
               :ok <- assert_loop_tool_result(messages, "grep", "deployment baton"),
               :ok <- assert_loop_tool_result(messages, "read", "deployment baton") do
            %{
              name: "agent_loop_workspace_memory_file_contract",
              status: :pass,
              details: %{
                tool_results: trace_tool_result_names(messages),
                memory_path: Path.relative_to(memory_path, project_dir)
              }
            }
          else
            {:error, reason} ->
              contract_fail(
                "agent_loop_workspace_memory_file_contract",
                format_reason(reason),
                %{}
              )
          end
        after
          File.rm_rf(tmp_dir)
        end

      {:error, reason} ->
        contract_fail("agent_loop_workspace_memory_file_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("agent_loop_workspace_memory_file_contract", Exception.message(e), %{})
  end

  @spec agent_loop_workspace_memory_update_contract_eval(String.t()) :: Types.eval_result()
  def agent_loop_workspace_memory_update_contract_eval(_cwd) do
    case create_tmp_dir() do
      {:ok, tmp_dir} ->
        try do
          project_dir = Path.join(tmp_dir, "project")
          home_dir = Path.join(tmp_dir, "home")
          memory_dir = Path.join([project_dir, "memory", "topics"])
          File.mkdir_p!(memory_dir)
          File.mkdir_p!(home_dir)

          memory_path = Path.join(memory_dir, "release-handoff.md")

          original_line =
            "Before answering release handoff questions, inspect this note and cite the deployment baton."

          updated_line =
            "Before answering release handoff questions, inspect this note, cite the deployment baton, and name the follow-up owner."

          File.write!(
            memory_path,
            """
            # Release Handoff

            The deployment baton lives in the workspace memory file.
            #{original_line}
            """
          )

          read_tool = Read.tool(project_dir)
          patch_tool = Patch.tool(project_dir)

          prompt =
            CodingAgent.SystemPrompt.build(project_dir, %{
              workspace_dir: home_dir,
              session_scope: :main,
              skill_context: "release handoff workspace memory update"
            })

          responses = [
            trace_tool_response([
              trace_tool_call(
                "read",
                %{
                  "path" => "memory/topics/release-handoff.md",
                  "limit" => 20
                },
                id: "call-read-memory-before-update"
              )
            ]),
            trace_tool_response([
              trace_tool_call(
                "patch",
                %{
                  "patch_text" => """
                  *** Begin Patch
                  *** Update File: memory/topics/release-handoff.md
                  @@
                  -#{original_line}
                  +#{updated_line}
                  *** End Patch
                  """
                },
                id: "call-patch-memory-topic"
              )
            ]),
            trace_final_response("Workspace memory was updated.")
          ]

          context =
            AgentContext.new(
              system_prompt: prompt,
              tools: [read_tool, patch_tool]
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
                  "We learned release handoffs must name the follow-up owner. Update project memory."
                )
              ],
              context,
              config,
              nil,
              nil
            )

          with {:ok, messages} <- EventStream.result(stream, 5_000),
               :ok <- assert_loop_tool_result(messages, "read", "deployment baton"),
               :ok <- assert_loop_tool_result(messages, "patch", "Patch applied successfully"),
               :ok <- assert_contains(File.read!(memory_path), "name the follow-up owner") do
            %{
              name: "agent_loop_workspace_memory_update_contract",
              status: :pass,
              details: %{
                tool_results: trace_tool_result_names(messages),
                memory_path: Path.relative_to(memory_path, project_dir)
              }
            }
          else
            {:error, reason} ->
              contract_fail(
                "agent_loop_workspace_memory_update_contract",
                format_reason(reason),
                %{}
              )
          end
        after
          File.rm_rf(tmp_dir)
        end

      {:error, reason} ->
        contract_fail("agent_loop_workspace_memory_update_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("agent_loop_workspace_memory_update_contract", Exception.message(e), %{})
  end

  @spec agent_loop_async_join_trace_contract_eval(String.t()) :: Types.eval_result()
  def agent_loop_async_join_trace_contract_eval(_cwd) do
    case create_tmp_dir() do
      {:ok, tmp_dir} ->
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

      {:error, reason} ->
        contract_fail("agent_loop_async_join_trace_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("agent_loop_async_join_trace_contract", Exception.message(e), %{})
  end

  @spec agent_loop_parallel_join_trace_contract_eval(String.t()) :: Types.eval_result()
  def agent_loop_parallel_join_trace_contract_eval(_cwd) do
    case create_tmp_dir() do
      {:ok, tmp_dir} ->
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

      {:error, reason} ->
        contract_fail("agent_loop_parallel_join_trace_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("agent_loop_parallel_join_trace_contract", Exception.message(e), %{})
  end

  @spec agent_loop_delegation_artifact_trace_contract_eval(String.t()) :: Types.eval_result()
  def agent_loop_delegation_artifact_trace_contract_eval(_cwd) do
    case create_tmp_dir() do
      {:ok, tmp_dir} ->
        try do
          clear_task_state()
          artifact_path = Path.join(tmp_dir, "reports/child-release-lane.md")

          task_tool =
            TaskTool.tool(tmp_dir,
              run_override: fn _on_update, _signal ->
                File.mkdir_p!(Path.dirname(artifact_path))
                File.write!(artifact_path, "# Child Release Lane\n\nchild side effect artifact\n")

                %AgentToolResult{
                  content: [
                    %TextContent{
                      text: "wrote reports/child-release-lane.md with child side effect artifact"
                    }
                  ],
                  details: %{status: "completed", artifact_path: "reports/child-release-lane.md"}
                }
              end,
              session_key: "agent:delegation-artifact-trace-eval:main",
              agent_id: "delegation-artifact-trace-eval",
              parent_run_id: "parent-run-delegation-artifact-trace"
            )

          read_tool = Read.tool(tmp_dir)

          context =
            AgentContext.new(
              system_prompt:
                "Delegate artifact creation, join the child, read the artifact, then answer.",
              tools: [task_tool, read_tool]
            )

          config = %AgentLoopConfig{
            model: trace_model(),
            convert_to_llm: &trace_convert_to_llm/1,
            stream_fn: delegation_artifact_stream_fn()
          }

          stream =
            Loop.agent_loop(
              [
                trace_user_message(
                  "Have a child create the release lane artifact, then verify it."
                )
              ],
              context,
              config,
              nil,
              nil
            )

          with {:ok, messages} <- EventStream.result(stream, 5_000),
               :ok <- assert_async_task_joined_with(messages, "child side effect artifact"),
               :ok <- assert_loop_tool_result(messages, "read", "child side effect artifact"),
               :ok <- assert_final_after_tool(messages, "read"),
               :ok <-
                 assert_final_contains(messages, [
                   "ARTIFACT_VERIFIED",
                   "child side effect artifact"
                 ]),
               true <- File.exists?(artifact_path) do
            %{
              name: "agent_loop_delegation_artifact_trace_contract",
              status: :pass,
              details: %{
                tool_results: trace_tool_result_names(messages),
                artifact: "reports/child-release-lane.md",
                verified_before_final: true
              }
            }
          else
            false ->
              contract_fail(
                "agent_loop_delegation_artifact_trace_contract",
                "artifact file missing",
                %{}
              )

            {:error, reason} ->
              contract_fail(
                "agent_loop_delegation_artifact_trace_contract",
                format_reason(reason),
                %{}
              )
          end
        after
          clear_task_state()
          File.rm_rf(tmp_dir)
        end

      {:error, reason} ->
        contract_fail(
          "agent_loop_delegation_artifact_trace_contract",
          format_reason(reason),
          %{}
        )
    end
  rescue
    e -> contract_fail("agent_loop_delegation_artifact_trace_contract", Exception.message(e), %{})
  end

  @spec delegation_toolset_contract_eval(String.t()) :: Types.eval_result()
  def delegation_toolset_contract_eval(cwd) do
    orchestrator_tools =
      ToolRegistry.get_tools(cwd,
        include_extensions: false,
        tool_policy: ToolPolicy.from_profile(:orchestrator)
      )

    leaf_tools =
      ToolRegistry.get_tools(cwd,
        include_extensions: false,
        tool_policy: ToolPolicy.from_profile(:leaf_worker)
      )

    with :ok <- assert_tool_available(orchestrator_tools, "task"),
         :ok <- assert_tool_available(orchestrator_tools, "agent"),
         :ok <- assert_tool_available(orchestrator_tools, "read"),
         :ok <- assert_tool_filtered(leaf_tools, "task"),
         :ok <- assert_tool_filtered(leaf_tools, "agent"),
         :ok <- assert_tool_available(leaf_tools, "read"),
         :ok <- assert_tool_available(leaf_tools, "write"),
         :ok <- assert_tool_available(leaf_tools, "bash") do
      %{
        name: "delegation_toolset_contract",
        status: :pass,
        details: %{
          orchestrator_delegates: true,
          leaf_blocks_recursive_delegation: true,
          leaf_tools:
            leaf_tools
            |> Enum.map(& &1.name)
            |> Enum.sort()
        }
      }
    else
      {:error, reason} ->
        contract_fail("delegation_toolset_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("delegation_toolset_contract", Exception.message(e), %{})
  end
end
