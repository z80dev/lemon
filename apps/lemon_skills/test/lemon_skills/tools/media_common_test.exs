defmodule LemonSkills.Tools.MediaCommonTest do
  use ExUnit.Case, async: true

  alias LemonAgent.AbortSignal
  alias LemonMedia.MediaJobs
  alias LemonSkills.Tools.MediaCommon

  @moduletag :tmp_dir

  test "redacts private fields and stringifies atoms through nested lists" do
    job = %{
      job_id: "job-1",
      type: :image,
      status: :completed,
      artifact: %{
        entries: [%{status: :ready, flags: [:one, :two], nested: [[nil, true, false]]}]
      },
      prompt: "private prompt",
      api_key: "private credential",
      error_kind: "private failure"
    }

    assert MediaCommon.redacted_job(job) == %{
             "job_id" => "job-1",
             "type" => "image",
             "status" => "completed",
             "artifact" => %{
               "entries" => [
                 %{
                   "status" => "ready",
                   "flags" => ["one", "two"],
                   "nested" => [["nil", "true", "false"]]
                 }
               ]
             }
           }
  end

  test "payload preserves prompt and input hash fields and opt-in delivery", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "preview.png")
    File.write!(path, "image")

    job = %{
      job_id: "job-1",
      type: :image,
      status: :completed,
      provider: "local_svg",
      model: "local_svg_preview",
      prompt_hash: "hash",
      prompt_chars: 12,
      artifact: %{name: "public.png", mime_type: "image/png"}
    }

    payload = MediaCommon.payload(job, path, "application/octet-stream", "prompt")
    assert payload["prompt_hash"] == "hash"
    assert payload["prompt_chars"] == 12
    refute Map.has_key?(payload, "input_hash")

    assert payload["artifact"] == %{
             "path" => path,
             "filename" => "public.png",
             "mime_type" => "image/png",
             "bytes" => 5
           }

    assert MediaCommon.maybe_auto_send(payload, %{}, "caption") == payload

    assert MediaCommon.maybe_auto_send(payload, %{"sendToChannel" => "true"}, "caption") ==
             payload

    assert MediaCommon.maybe_auto_send(payload, %{"sendToChannel" => true}, "caption")[
             "auto_send_files"
           ] == [
             %{
               "path" => path,
               "filename" => "public.png",
               "caption" => "caption",
               "source" => "generated"
             }
           ]

    input_payload = MediaCommon.payload(%{job | artifact: nil}, path, "text/plain", "input")
    assert input_payload["input_hash"] == "hash"
    assert input_payload["input_chars"] == 12
    refute Map.has_key?(input_payload, "prompt_hash")
    assert input_payload["artifact"]["filename"] == "preview.png"
    assert input_payload["artifact"]["mime_type"] == "text/plain"
  end

  test "timeouts retain caller-specific defaults and limits" do
    for {default, maximum} <- [{5_000, 30_000}, {10_000, 120_000}, {20_000, 300_000}] do
      assert MediaCommon.timeout_ms(%{}, default, maximum) == {:ok, default}
      assert MediaCommon.timeout_ms(%{"timeoutMs" => 1}, default, maximum) == {:ok, 100}

      assert MediaCommon.timeout_ms(%{"timeoutMs" => "999999"}, default, maximum) ==
               {:ok, maximum}

      assert MediaCommon.timeout_ms(%{"timeoutMs" => "1250"}, default, maximum) == {:ok, 1250}

      assert MediaCommon.timeout_ms(%{"timeoutMs" => "1250ms"}, default, maximum) ==
               {:error, "timeoutMs must be an integer"}
    end
  end

  test "artifact paths preserve per-tool filename prefixes and sanitize names", %{
    tmp_dir: tmp_dir
  } do
    for prefix <- ~w(media-preview media-speech media-video media-analysis media-transcript) do
      assert {:ok, path} =
               MediaCommon.artifact_path(%{}, tmp_dir, [output_guard: :none], "json", prefix)

      assert Path.basename(path) =~ ~r/^#{prefix}-\d+\.json$/
      assert Path.dirname(path) == Path.join(tmp_dir, ".lemon/media-artifacts")
    end

    assert {:ok, path} =
             MediaCommon.artifact_path(
               %{"filename" => "../unsafe file.PNG"},
               tmp_dir,
               [media_artifacts_dir: tmp_dir, output_guard: :none],
               "png",
               "media-preview"
             )

    assert path == Path.join(tmp_dir, "unsafe_file.PNG")
  end

  test "artifact paths fail closed without an output guard", %{tmp_dir: tmp_dir} do
    assert {:error, message} = MediaCommon.artifact_path(%{}, tmp_dir, [], "png", "media")
    assert message =~ "output guard is not configured"

    refuse = fn _path -> {:error, "refused"} end

    assert {:error, "refused"} =
             MediaCommon.artifact_path(%{}, tmp_dir, [output_guard: refuse], "png", "media")
  end

  test "returns completed jobs and failed-job error kinds", %{tmp_dir: tmp_dir} do
    opts = [dir: tmp_dir, runner: fn _attrs -> {:ok, %{}} end]
    assert {:ok, %{status: :completed}} = MediaCommon.run_job(%{type: :image}, opts, 1_000, nil)

    opts = [dir: tmp_dir, runner: fn _attrs -> {:error, :safe_failure} end]

    assert MediaCommon.run_job(%{type: :image}, opts, 1_000, nil) ==
             {:error, "media job failed: safe_failure"}
  end

  test "100 unrelated media_jobs events do not extend the deadline", %{tmp_dir: tmp_dir} do
    for n <- 1..100, do: send(self(), {:media_job, :running, %{job_id: "other-#{n}"}})
    started = System.monotonic_time(:millisecond)
    opts = [dir: tmp_dir, runner: fn _attrs -> Process.sleep(:infinity) end]

    assert {:error, message} =
             MediaCommon.run_job(%{job_id: "slow-job", type: :image}, opts, 200, nil)

    assert System.monotonic_time(:millisecond) - started < 1_000

    assert message ==
             "media job slow-job timed out after 200ms and was cancelled; see media_status"

    assert [%{job_id: "slow-job", status: :cancelled}] = MediaJobs.recent(dir: tmp_dir)
    assert {:messages, messages} = Process.info(self(), :messages)
    assert length(messages) == 100
  end

  test "abort cancels the running job", %{tmp_dir: tmp_dir} do
    signal = AbortSignal.new()
    parent = self()

    runner = fn _attrs ->
      send(parent, {:started, self()})
      AbortSignal.abort(signal)
      Process.sleep(:infinity)
    end

    assert {:error, "Operation aborted"} =
             MediaCommon.run_job(%{type: :image}, [dir: tmp_dir, runner: runner], 5_000, signal)

    assert_received {:started, pid}
    refute Process.alive?(pid)
    assert [%{status: :cancelled, error_kind: "aborted"}] = MediaJobs.recent(dir: tmp_dir)
  end

  test "explicit provider keys bypass credential resolution" do
    assert MediaCommon.provider_api_key(%{api_key: "key"}, :missing_key) == {:ok, "key"}
    assert MediaCommon.provider_api_key(%{api_key: "key"}, :missing_key, :other) == {:ok, "key"}
  end
end
