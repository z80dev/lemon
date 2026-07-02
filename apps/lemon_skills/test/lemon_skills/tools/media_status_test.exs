defmodule LemonSkills.Tools.MediaStatusTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias LemonCore.MediaJobs

  @moduletag :tmp_dir

  test "returns redacted media job summary and recent jobs", %{tmp_dir: tmp_dir} do
    artifact_dir = MediaJobs.default_artifacts_dir(tmp_dir)
    artifact_path = Path.join(artifact_dir, "preview.svg")
    File.mkdir_p!(artifact_dir)
    File.write!(artifact_path, "<svg></svg>")

    {:ok, _job} =
      MediaJobs.record(
        %{
          type: :image,
          status: :completed,
          provider: "local_svg",
          model: "local_svg_preview",
          prompt: "private prompt",
          artifact_path: artifact_path,
          mime_type: "image/svg+xml"
        },
        project_dir: tmp_dir
      )

    tool = LemonSkills.Tools.MediaStatus.tool(tmp_dir)
    assert %AgentToolResult{} = result = tool.execute.("call-1", %{"limit" => 5}, nil, nil)

    assert result.details["summary"]["count"] == 1
    assert result.details["summary"]["artifact_count"] == 1
    assert result.details["worker_status"]["supervised"] == true

    assert [
             %{
               "status" => "completed",
               "type" => "image",
               "prompt_hash" => prompt_hash,
               "artifact" => %{"path_hash" => path_hash}
             }
           ] = result.details["recent"]

    assert is_binary(prompt_hash)
    assert is_binary(path_hash)
    refute inspect(result.details) =~ "private prompt"
    refute inspect(result.details) =~ artifact_path
  end
end
