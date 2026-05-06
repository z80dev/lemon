defmodule CodingAgent.Evals.Harness do
  @moduledoc """
  Lightweight quality evaluation harness for coding workflows.

  The suite runs three evaluation classes:
  - deterministic contract checks
  - statistical stability checks
  - workflow scenario checks
  """

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.{PromptBuilder, ToolRegistry}
  alias CodingAgent.Tools.{MemoryTopic, ReadSkill, SearchMemory, SkillManage}
  alias LemonSkills.Curator

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

    results = [
      deterministic_contract_eval(cwd),
      statistical_stability_eval(cwd, iterations),
      read_edit_workflow_eval(cwd),
      memory_scope_contract_eval(cwd),
      memory_topic_contract_eval(cwd),
      auto_skill_prompt_contract_eval(cwd),
      skill_curator_behavior_contract_eval(cwd),
      learning_tool_trace_contract_eval(cwd),
      tool_use_claim_contract_eval(cwd)
    ]

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

  defp contract_fail(name, reason, details) do
    %{name: name, status: :fail, details: Map.merge(%{reason: reason}, details)}
  end

  defp normalized_tool_names(cwd) do
    cwd
    |> ToolRegistry.list_tool_names(include_extensions: false)
    |> Enum.sort()
  end

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

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
