defmodule LemonRouter.RunProcess.ArtifactTrackerTest do
  use ExUnit.Case, async: true

  alias LemonRouter.RunProcess.ArtifactTracker

  test "track_generated_images/2 keeps only added image paths from completed file_change actions" do
    state = %{generated_image_paths: []}

    action_event = %{
      phase: :completed,
      ok: true,
      action: %{
        kind: "file_change",
        detail: %{
          changes: [
            %{path: "artifacts/chart.png", kind: "added"},
            %{path: "notes.txt", kind: "added"},
            %{path: "artifacts/old.jpg", kind: "deleted"}
          ]
        }
      }
    }

    assert ArtifactTracker.track_generated_images(state, action_event).generated_image_paths == [
             "artifacts/chart.png"
           ]
  end

  test "tracking helpers tolerate missing state keys" do
    action_event = %{
      phase: :completed,
      ok: true,
      action: %{
        kind: "file_change",
        detail: %{changes: [%{path: "artifacts/chart.png", kind: "added"}]}
      }
    }

    assert ArtifactTracker.track_generated_images(%{}, action_event).generated_image_paths == [
             "artifacts/chart.png"
           ]

    assert ArtifactTracker.track_requested_send_files(%{}, %{
             phase: :completed,
             ok: true,
             action: %{detail: %{result_meta: %{auto_send_files: [%{path: "notes.txt"}]}}}
           }).requested_send_files == [
             %{path: "notes.txt", filename: "notes.txt", caption: nil}
           ]
  end

  test "track_requested_send_files/2 normalizes explicit file requests from result metadata" do
    state = %{requested_send_files: []}

    action_event = %{
      phase: :completed,
      ok: true,
      action: %{
        kind: "tool",
        detail: %{
          result_meta: %{
            auto_send_files: [
              %{path: "workspace/image.png", filename: "custom.png", caption: "Generated"},
              %{"path" => "workspace/report.txt"}
            ]
          }
        }
      }
    }

    assert ArtifactTracker.track_requested_send_files(state, action_event).requested_send_files ==
             [
               %{path: "workspace/image.png", filename: "custom.png", caption: "Generated"},
               %{path: "workspace/report.txt", filename: "report.txt", caption: nil}
             ]
  end

  test "finalize_meta/1 returns auto_send_files only for valid existing files within cwd" do
    cwd = tmp_dir!("artifact-tracker-valid")
    generated = canonical_path(write_file!(cwd, "artifacts/chart.png", "png"))
    explicit = canonical_path(write_file!(cwd, "reports/final.txt", "report"))

    state = %{
      execution_request: request(cwd),
      generated_image_paths: ["artifacts/chart.png"],
      requested_send_files: [%{path: "reports/final.txt", caption: "Final report"}]
    }

    assert ArtifactTracker.finalize_meta(state) == %{
             auto_send_files: [
               %{
                 path: explicit,
                 filename: "final.txt",
                 caption: "Final report",
                 source: :explicit
               },
               %{
                 path: generated,
                 filename: "chart.png",
                 caption: nil,
                 source: :generated
               }
             ]
           }
  end

  test "finalize_meta/1 dedupes merged generated and explicit files" do
    cwd = tmp_dir!("artifact-tracker-dedupe")
    file = canonical_path(write_file!(cwd, "artifacts/chart.png", "png"))

    state = %{
      execution_request: request(cwd),
      generated_image_paths: ["artifacts/chart.png"],
      requested_send_files: [%{path: "artifacts/chart.png"}]
    }

    assert ArtifactTracker.finalize_meta(state) == %{
             auto_send_files: [
               %{
                 path: file,
                 filename: "chart.png",
                 caption: nil,
                 source: :explicit
               }
             ]
           }
  end

  test "finalize_meta/1 preserves distinct filenames for the same file path" do
    cwd = tmp_dir!("artifact-tracker-filenames")
    file = canonical_path(write_file!(cwd, "reports/final.txt", "report"))

    state = %{
      execution_request: request(cwd),
      requested_send_files: [
        %{path: "reports/final.txt", filename: "first.txt"},
        %{path: "reports/final.txt", filename: "second.txt"}
      ]
    }

    assert ArtifactTracker.finalize_meta(state) == %{
             auto_send_files: [
               %{path: file, filename: "first.txt", caption: nil, source: :explicit},
               %{path: file, filename: "second.txt", caption: nil, source: :explicit}
             ]
           }
  end

  test "finalize_meta/1 rejects paths outside cwd" do
    cwd = tmp_dir!("artifact-tracker-cwd")
    outside_dir = tmp_dir!("artifact-tracker-outside")
    outside = write_file!(outside_dir, "outside.txt", "secret")

    state = %{
      execution_request: request(cwd),
      generated_image_paths: ["../outside.png"],
      requested_send_files: [%{path: outside, caption: "Nope"}]
    }

    assert ArtifactTracker.finalize_meta(state) == %{}
  end

  test "finalize_meta/1 rejects symlinked files that escape cwd" do
    cwd = tmp_dir!("artifact-tracker-symlink-root")
    outside_dir = tmp_dir!("artifact-tracker-symlink-outside")
    outside = write_file!(outside_dir, "secret.png", "secret")
    link_path = Path.join(cwd, "artifacts/escape.png")

    File.mkdir_p!(Path.dirname(link_path))
    File.ln_s!(outside, link_path)

    state = %{
      execution_request: request(cwd),
      generated_image_paths: ["artifacts/escape.png"],
      requested_send_files: [%{path: "artifacts/escape.png", filename: "escape.png"}]
    }

    assert ArtifactTracker.finalize_meta(state) == %{}
  end

  defp tmp_dir!(suffix) do
    path = Path.join(System.tmp_dir!(), "#{suffix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp write_file!(cwd, relative_path, contents) do
    path = Path.join(cwd, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp request(cwd) do
    %LemonGateway.ExecutionRequest{
      run_id: "run-artifacts",
      session_key: "agent:test:main",
      prompt: "test",
      engine_id: "echo",
      cwd: cwd
    }
  end

  defp canonical_path(path) do
    path
    |> Path.expand()
    |> resolve_absolute_path()
  end

  defp resolve_absolute_path(path) do
    case Path.split(path) do
      [root | segments] -> resolve_absolute_segments(root, segments)
      _ -> path
    end
  end

  defp resolve_absolute_segments(current, []), do: current

  defp resolve_absolute_segments(current, [segment | rest]) do
    next = Path.join(current, segment)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, target} = File.read_link(next)

        target_path =
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, Path.dirname(next))
          end

        combined =
          case rest do
            [] -> target_path
            _ -> Path.join([target_path | rest])
          end

        resolve_absolute_path(combined)

      {:ok, _stat} ->
        resolve_absolute_segments(next, rest)

      _ ->
        next
    end
  end
end
