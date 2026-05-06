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
      skill_curator_behavior_contract_eval(cwd)
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
