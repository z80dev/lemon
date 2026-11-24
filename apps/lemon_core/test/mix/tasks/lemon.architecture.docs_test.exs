defmodule Mix.Tasks.Lemon.Architecture.DocsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Architecture.Docs, as: ArchitectureDocsTask

  setup do
    Mix.Task.reenable("lemon.architecture.docs")

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_architecture_docs_task_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, "docs"))
    File.mkdir_p!(Path.join(tmp_dir, "scripts"))
    File.write!(Path.join(tmp_dir, "scripts/verify_packages"), "PACKAGES=()\n")

    on_exit(fn ->
      Mix.Task.reenable("lemon.architecture.docs")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "--check passes when architecture docs are current", %{tmp_dir: tmp_dir} do
    write_architecture_doc(tmp_dir, "placeholder")

    capture_io(fn ->
      ArchitectureDocsTask.run(["--root", tmp_dir])
    end)

    output =
      capture_io(fn ->
        ArchitectureDocsTask.run(["--check", "--root", tmp_dir])
      end)

    assert output =~ "[ok] architecture docs are up to date"
  end

  test "--check fails when architecture docs are stale", %{tmp_dir: tmp_dir} do
    write_architecture_doc(tmp_dir, "stale")

    assert_raise Mix.Error, ~r/Architecture boundaries doc is stale/, fn ->
      capture_io(fn ->
        ArchitectureDocsTask.run(["--check", "--root", tmp_dir])
      end)
    end
  end

  defp write_architecture_doc(root, body) do
    File.write!(Path.join(root, "docs/architecture_boundaries.md"), """
    # Architecture Boundaries

    ## Direct Dependency Policy

    <!-- architecture_policy:start -->
    #{body}
    <!-- architecture_policy:end -->

    ## Package Map

    <!-- package_map:start -->
    #{body}
    <!-- package_map:end -->
    """)
  end
end
