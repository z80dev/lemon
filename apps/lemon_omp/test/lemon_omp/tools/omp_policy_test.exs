defmodule LemonOmp.Tools.OmpPolicyTest do
  # Drives the fake omp through the agent tool; shares the live-session cap.
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  alias LemonCore.ToolPolicy
  alias LemonOmp.Tools.Omp

  setup do
    use_fake_omp()
    ws = workspace!()
    key = "agent:omp-policy-test:#{System.unique_integer([:positive])}"
    {:ok, ws: ws, key: key}
  end

  defp tool(ctx, policy, extra \\ []),
    do: Omp.tool(ctx.ws, [session_key: ctx.key, tool_policy: policy] ++ extra)

  defp run(tool, params),
    do: tool.execute.("call-#{System.unique_integer([:positive])}", params, nil, nil)

  defp launched?(dir),
    do:
      File.exists?(Path.join(dir, ".fake_omp.args")) or
        File.exists?(Path.join(dir, ".fake_omp.pid"))

  defp custom(opts), do: ToolPolicy.custom(opts)

  test "restricted profiles cannot start, batch-start or resume omp in yolo", ctx do
    for profile <- [:safe_mode, :subagent_restricted, :leaf_worker, :read_only] do
      tool = tool(ctx, ToolPolicy.from_profile(profile))

      for params <- [
            %{"action" => "start", "prompt" => "HOLD", "approval_mode" => "yolo"},
            %{"action" => "start", "prompt" => "HOLD"},
            %{
              "action" => "start_many",
              "tasks" => [%{"prompt" => "HOLD", "approval_mode" => "yolo"}]
            },
            %{
              "action" => "resume",
              "omp_session_id" => "fake-session-0001",
              "prompt" => "HOLD",
              "approval_mode" => "yolo"
            }
          ] do
        result = run(tool, params)
        assert result.is_error, "#{profile} ran #{inspect(params)}"
        refute launched?(ctx.ws), "#{profile} launched omp for #{inspect(params)}"
      end
    end
  end

  test "a policy that forbids or reviews execution cannot start omp in yolo", ctx do
    for policy <- [
          custom(deny: ["bash"]),
          custom(deny: ["write", "edit"]),
          custom(approval_mode: :ask),
          custom(approval_mode: :write),
          custom(require_approval: ["bash"])
        ] do
      result =
        run(tool(ctx, policy), %{
          "action" => "start",
          "prompt" => "HOLD",
          "approval_mode" => "yolo"
        })

      assert result.is_error
      assert result.details["error"] == "approval_mode_not_permitted"
      refute launched?(ctx.ws)
    end
  end

  test "an omitted approval mode is pinned to the caller's ceiling", ctx do
    result =
      run(tool(ctx, custom(approval_mode: :ask)), %{"action" => "start", "prompt" => "HOLD"})

    refute result.is_error
    assert result.details["session"]["approvalMode"] == "always-ask"
    assert File.read!(Path.join(ctx.ws, ".fake_omp.args")) =~ "--approval-mode always-ask"
  end

  test "a missing caller policy fails closed", ctx do
    result =
      run(Omp.tool(ctx.ws, session_key: ctx.key), %{"action" => "start", "prompt" => "HOLD"})

    assert result.is_error
    refute launched?(ctx.ws)
  end

  test "a reviewed policy cannot start omp outside its workspace", ctx do
    policy = custom(approval_mode: :ask)
    outside = workspace!()
    link = Path.join(ctx.ws, "escape")
    File.ln_s!(outside, link)

    for cwd <- ["/", outside, link, Path.join(ctx.ws, "..")] do
      for params <- [
            %{"action" => "start", "prompt" => "HOLD", "cwd" => cwd},
            %{"action" => "start_many", "tasks" => [%{"prompt" => "HOLD", "cwd" => cwd}]},
            %{"action" => "discover", "cwd" => cwd}
          ] do
        result = run(tool(ctx, policy), params)
        assert result.is_error, "started at #{cwd}: #{inspect(params)}"
        assert result.details["error"] == "invalid_cwd"
      end
    end

    refute launched?(outside)

    inside = Path.join(ctx.ws, "pkg")
    File.mkdir_p!(inside)
    File.write!(Path.join(inside, ".fake_omp_mode"), "normal")
    result = run(tool(ctx, policy), %{"action" => "start", "prompt" => "HOLD", "cwd" => inside})
    refute result.is_error
    # The launched cwd is the symlink-resolved directory (macOS tmp is /private/var).
    assert String.ends_with?(result.details["session"]["cwd"], "/pkg")
    assert File.read!(Path.join(inside, ".fake_omp.args")) =~ "--approval-mode always-ask"
  end

  test "full access keeps yolo and any directory", ctx do
    other = workspace!()
    tool = tool(ctx, ToolPolicy.from_profile(:full_access))

    result =
      run(tool, %{
        "action" => "start",
        "prompt" => "HOLD",
        "approval_mode" => "yolo",
        "cwd" => other
      })

    refute result.is_error
    assert File.read!(Path.join(other, ".fake_omp.args")) =~ "--approval-mode yolo"
  end

  test "command lists refuse omp delegation, which cannot enforce them", ctx do
    for policy <- [
          custom(allow: ~w(omp bash write edit), allowed_commands: []),
          custom(allow: ~w(omp bash write edit), allowed_commands: ["git status"]),
          custom(allow: ~w(omp bash write edit), blocked_commands: ["rm -rf"])
        ],
        params <- [
          %{"action" => "start", "prompt" => "HOLD"},
          %{"action" => "start", "prompt" => "HOLD", "approval_mode" => "always-ask"},
          %{"action" => "start_many", "tasks" => [%{"prompt" => "HOLD"}]},
          %{"action" => "resume", "omp_session_id" => "fake-session-0001", "prompt" => "HOLD"}
        ] do
      result = run(tool(ctx, policy), params)
      assert result.is_error, "ran #{inspect(params)}"
      assert result.details["error"] == "command_lists_not_enforced"
      refute launched?(ctx.ws)
    end
  end

  test "send refuses a worker that exceeds the current policy", ctx do
    outside = workspace!()
    full = tool(ctx, ToolPolicy.from_profile(:full_access))

    started =
      run(full, %{"action" => "start", "prompt" => "HOLD", "cwd" => outside})

    refute started.is_error
    id = started.details["session"]["id"]

    # The yolo worker outside the workspace, reached after the policy narrowed.
    for {policy, error} <- [
          {custom(approval_mode: :ask), "worker_exceeds_policy"},
          {custom(approval_mode: :write), "worker_exceeds_policy"},
          {custom(allow: ~w(omp bash write edit), allowed_commands: []),
           "command_lists_not_enforced"}
        ] do
      result = run(tool(ctx, policy), %{"action" => "send", "id" => id, "message" => "rm -rf /"})
      assert result.is_error
      assert result.details["error"] == error
    end

    # Same mode ceiling, but the worker's workspace is outside the caller's.
    reviewed =
      run(full, %{
        "action" => "start",
        "prompt" => "HOLD",
        "approval_mode" => "always-ask",
        "cwd" => outside
      })

    reviewed_id = reviewed.details["session"]["id"]

    result =
      run(tool(ctx, custom(approval_mode: :ask)), %{
        "action" => "send",
        "id" => reviewed_id,
        "message" => "more"
      })

    assert result.details["error"] == "worker_exceeds_policy"

    refute run(full, %{"action" => "send", "id" => id, "message" => "ok"}).is_error

    for wid <- [id, reviewed_id], do: run(full, %{"action" => "close", "id" => wid})
  end
end
