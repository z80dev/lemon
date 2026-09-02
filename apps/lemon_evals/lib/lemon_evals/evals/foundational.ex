defmodule LemonEvals.Evals.Foundational do
  @moduledoc """
  Deterministic and statistical baseline checks: builtin tool registry
  contract, tool-name stability across repeated loads, and the basic
  read/edit tool workflow.
  """

  import LemonEvals.Support

  alias CodingAgent.ToolRegistry
  alias LemonEvals.Types

  @required_builtin_tools ~w(read read_skill skill_manage memory_topic memory search_memory session_search checkpoint write edit patch bash grep find ls webfetch websearch browser_navigate browser_snapshot browser_get_content browser_click browser_type browser_hover browser_select_option browser_upload_file browser_download browser_press browser_scroll browser_back browser_wait_for_selector browser_evaluate browser_events browser_get_cookies browser_set_cookies browser_clear_state browser_screenshot todo task extensions_status)

  @spec deterministic_contract_eval(String.t()) :: Types.eval_result()
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

  @spec statistical_stability_eval(String.t(), pos_integer()) :: Types.eval_result()
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

  @spec read_edit_workflow_eval(String.t()) :: Types.eval_result()
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
      _ = File.rm_rf(tmp_dir)

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

  defp normalized_tool_names(cwd) do
    cwd
    |> ToolRegistry.list_tool_names(include_extensions: false)
    |> Enum.sort()
  end
end
