defmodule CodingAgent.RetiredToolFeaturesTest do
  @moduledoc """
  Write-only and unreachable tool features stay deleted (#706): the remaining
  tool inventory keeps one entry point per capability.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.{InternalUrls, ToolRegistry}
  alias CodingAgent.Tools.{ExtensionsStatus, Read}

  @moduletag :tmp_dir

  @retired_modules [
    CodingAgent.Tools.FeatureRequirements,
    CodingAgent.InternalUrls.NotesProtocol,
    CodingAgent.Tools.TodoStore,
    CodingAgent.Tools.TodoStoreOwner,
    CodingAgent.Tools.TodoRead,
    CodingAgent.Tools.TodoWrite,
    CodingAgent.Tools.ReportIssue,
    CodingAgent.Tools.ReadJson,
    CodingAgent.Tools.WriteArchive,
    CodingAgent.Tools.WriteSqlite
  ]

  @kept_builtins ~w(read read_skill skill_manage remember recall fs_checkpoint checkpoint
    rewind write edit patch lsp_diagnostics lsp bash bash_output kill_process process_input
    eval debug grep ast_grep find semantic_find ls webfetch websearch todo ask kanban goal
    peer task agent_message wait agent nodes parent_question extensions_status)a

  test "retired modules are gone" do
    for module <- @retired_modules, do: refute(Code.ensure_loaded?(module), inspect(module))
  end

  test "built-ins keep every live tool and drop only report_issue" do
    names = ToolRegistry.builtin_tool_names()

    assert @kept_builtins -- names == []
    refute :report_issue in names
    refute Enum.any?(names, &(&1 in [:todoread, :todowrite, :read_json]))
  end

  test "the policy catalogue no longer classifies retired tool names" do
    for name <- ~w(report_issue todoread todowrite),
        do: assert(LemonCore.ToolCatalog.fetch(name) == :error)
  end

  test "extensions_status is status-only" do
    tool = ExtensionsStatus.tool("/tmp")

    assert Map.keys(tool.parameters["properties"]) == ["include_details"]
    refute tool.description =~ ~r/reload/i
  end

  test "notes:// is not an internal URL" do
    refute InternalUrls.internal_url?("notes://plan.md")
  end

  test "read refuses directories; ls is the directory listing", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "entry.txt"), "content")

    assert {:error, message} = Read.execute("call", %{"path" => tmp_dir}, nil, nil, tmp_dir, [])
    assert message =~ "directory"
    assert message =~ "ls"
  end
end
