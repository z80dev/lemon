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
  alias CodingAgent.Tools.{MemoryTopic, SearchMemory}

  @required_builtin_tools ~w(read read_skill memory_topic search_memory write edit patch bash grep find ls webfetch websearch todo task extensions_status)

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
      auto_skill_prompt_contract_eval(cwd)
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
          File.rm_rf(tmp_dir)

          %{
            name: "memory_topic_contract",
            status: :pass,
            details: %{slug: result.details[:slug], path: result.details[:path]}
          }
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
          File.rm_rf(tmp_dir)

          %{
            name: "auto_skill_prompt_contract",
            status: :pass,
            details: %{skill: "hermes-memory", progressive_disclosure: true}
          }
      end
    else
      {:error, reason} -> contract_fail("auto_skill_prompt_contract", format_reason(reason), %{})
    end
  rescue
    e -> contract_fail("auto_skill_prompt_contract", Exception.message(e), %{})
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

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
