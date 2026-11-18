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
              %{
                path: "workspace/image.png",
                filename: "custom.png",
                caption: "Generated",
                source: :generated
              },
              %{"path" => "workspace/report.txt"}
            ]
          }
        }
      }
    }

    assert ArtifactTracker.track_requested_send_files(state, action_event).requested_send_files ==
             [
               %{
                 path: "workspace/image.png",
                 filename: "custom.png",
                 caption: "Generated",
                 source: :generated
               },
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

  test "finalize_meta/2 turns final-answer MEDIA directives into explicit files" do
    cwd = tmp_dir!("artifact-tracker-media-directive")
    file = canonical_path(write_file!(cwd, "artifacts/chart.png", "png"))
    write_file!(cwd, "notes.txt", "notes")

    outside_dir = tmp_dir!("artifact-tracker-media-directive-outside")
    outside = write_file!(outside_dir, "secret.png", "secret")

    state = %{
      execution_request: request(cwd),
      requested_send_files: [%{path: "notes.txt", caption: "Notes"}]
    }

    answer = """
    Done.
    MEDIA: artifacts/chart.png
    inline MEDIA: notes.txt
    MEDIA: missing.png
    MEDIA: #{outside}
    """

    assert ArtifactTracker.finalize_meta(state, answer) == %{
             auto_send_files: [
               %{
                 path: canonical_path(Path.join(cwd, "notes.txt")),
                 filename: "notes.txt",
                 caption: "Notes",
                 source: :explicit
               },
               %{path: file, filename: "chart.png", caption: nil, source: :explicit}
             ]
           }
  end

  test "finalize_meta/2 dedupes MEDIA directives against explicit file requests" do
    cwd = tmp_dir!("artifact-tracker-media-directive-dedupe")
    file = canonical_path(write_file!(cwd, "artifacts/chart.png", "png"))

    state = %{
      execution_request: request(cwd),
      requested_send_files: [%{path: "artifacts/chart.png"}]
    }

    answer = """
    MEDIA:artifacts/chart.png
    MEDIA: `artifacts/chart.png`
    """

    assert ArtifactTracker.finalize_meta(state, answer) == %{
             auto_send_files: [
               %{path: file, filename: "chart.png", caption: nil, source: :explicit}
             ]
           }
  end

  test "strip_media_directives/1 removes host-visible MEDIA lines from final text" do
    answer = """
    Here is the chart.
    MEDIA: artifacts/chart.png
    Inline MEDIA: artifacts/chart.png stays text.
    MEDIA:
    """

    assert ArtifactTracker.strip_media_directives(answer) ==
             "Here is the chart.\nInline MEDIA: artifacts/chart.png stays text."
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

  describe "runs without a cwd (remote-node runs)" do
    import ExUnit.CaptureLog

    test "a MEDIA directive naming a controller file sends nothing and logs the rejection" do
      state = %{execution_request: request(nil)}
      answer = "Here you go\nMEDIA: /etc/passwd"

      log = capture_log(fn -> assert ArtifactTracker.finalize_meta(state, answer) == %{} end)

      assert log =~ "no working directory"
      assert log =~ "/etc/passwd"
    end

    test "tool-requested and generated absolute files are dropped" do
      outside = write_file!(tmp_dir!("artifact-tracker-nil-cwd"), "secrets_master_key", "k")
      image = write_file!(tmp_dir!("artifact-tracker-nil-cwd-img"), "chart.png", "png")

      state = %{
        execution_request: request(nil),
        requested_send_files: [%{path: outside, filename: "key"}],
        generated_image_paths: [image]
      }

      log = capture_log(fn -> assert ArtifactTracker.finalize_meta(state, nil) == %{} end)
      assert log =~ "secrets_master_key"
    end

    test "an empty-string cwd is treated as no cwd" do
      state = %{execution_request: request(""), requested_send_files: [%{path: "/etc/hosts"}]}

      capture_log(fn -> assert ArtifactTracker.finalize_meta(state, nil) == %{} end)
    end
  end

  describe "retained delivery copies" do
    # Called through a variable: lemon_router does not depend on coding_agent,
    # but the umbrella test run loads both.
    @send_file CodingAgent.Tools.SendFile

    defp channel_key do
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "discord",
        account_id: "bot",
        peer_kind: :dm,
        peer_id: "#{System.unique_integer([:positive])}"
      })
    end

    defp send_file_event(details) do
      %{phase: :completed, ok: true, action: %{kind: "tool", detail: %{result_meta: details}}}
    end

    test "send_file delivers the validated bytes after a delayed source swap" do
      cwd = tmp_dir!("artifact-tracker-swap")
      outside = write_file!(tmp_dir!("artifact-tracker-swap-out"), "secret.txt", "SECRET")
      source = write_file!(cwd, "report.txt", "VALIDATED")
      session_key = channel_key()
      send_file = @send_file

      result =
        send_file.tool(cwd, session_key: session_key).execute.(
          "call",
          %{"path" => "report.txt", "caption" => "Weekly"},
          nil,
          nil
        )

      assert %{auto_send_files: [%{path: copy}]} = result.details
      refute String.starts_with?(canonical_path(copy), canonical_path(cwd) <> "/")

      request = %{request(cwd) | session_key: session_key}

      state =
        ArtifactTracker.track_requested_send_files(
          %{execution_request: request},
          send_file_event(result.details)
        )

      # The source is swapped for a link to an outside secret before completion.
      File.rm!(source)
      File.ln_s!(outside, source)

      assert %{auto_send_files: [file]} = ArtifactTracker.finalize_meta(state, nil)
      assert %{path: ^copy, filename: "report.txt", caption: "Weekly"} = file
      assert File.read!(file.path) == "VALIDATED"

      # Provenance is one-shot.
      assert ArtifactTracker.finalize_meta(state, nil) == %{}
    end

    test "registered copies are delivered for runs without a cwd" do
      session_key = channel_key()
      {:ok, copy} = LemonCore.FileAccess.retain_copy("chart.png", "png")
      :ok = LemonCore.OutboundCopies.register(session_key, copy)

      state = %{
        execution_request: %{request(nil) | session_key: session_key},
        requested_send_files: [%{path: copy, filename: "chart.png"}]
      }

      assert %{auto_send_files: [%{path: ^copy}]} = ArtifactTracker.finalize_meta(state, nil)
    end

    test "an unregistered or foreign-session path outside cwd is dropped" do
      cwd = tmp_dir!("artifact-tracker-forged")
      {:ok, forged} = LemonCore.FileAccess.retain_copy("forged.txt", "x")
      {:ok, foreign} = LemonCore.FileAccess.retain_copy("foreign.txt", "y")
      :ok = LemonCore.OutboundCopies.register(channel_key(), foreign)

      state = %{
        execution_request: %{request(cwd) | session_key: channel_key()},
        requested_send_files: [%{path: forged}, %{path: foreign}]
      }

      assert ArtifactTracker.finalize_meta(state, nil) == %{}
    end
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
    %LemonCore.ExecutionCommand{
      run_id: "run-artifacts",
      session_key: "agent:test:main",
      prompt: "test",
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
