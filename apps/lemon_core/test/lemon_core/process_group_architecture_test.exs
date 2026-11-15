defmodule LemonCore.ProcessGroupArchitectureTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @signal_owner "apps/lemon_core/lib/lemon_core/process_group.ex"
  @retired [
    :kill_process_tree,
    :terminate_process_tree,
    :signal_workload_group,
    :signal_group,
    :signal_pids
  ]
  @kill_commands ~w(kill pkill killall taskkill taskkill.exe)

  test "OS workload termination is implemented only by ProcessGroup" do
    violations =
      @root
      |> Path.join("apps/*/lib/**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        relative = Path.relative_to(path, @root)

        if relative == @signal_owner do
          []
        else
          path
          |> File.read!()
          |> signal_calls()
          |> Enum.reject(fn {_line, call} -> allowed_call?(relative, call) end)
          |> Enum.map(fn {line, call} -> "#{relative}:#{line}: #{Macro.to_string(call)}" end)
        end
      end)

    assert violations == [],
           "Route workload termination through LemonCore.ProcessGroup.terminate/2:\n" <>
             Enum.join(violations, "\n")
  end

  test "native sources cannot silently introduce another signal implementation" do
    # NativeProcess currently launches ports in Elixir; there is no C runner to
    # exempt. Any future native runner must receive an explicit, reviewed path
    # exception here rather than allowing every native source to signal workloads.
    violations =
      @root
      |> Path.join("apps/*/{c_src,native,lib}/**/*.{c,h,cc,cpp,rs}")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        Regex.match?(
          ~r/\b(?:kill|killpg|TerminateProcess|TerminateJobObject)\s*\(/,
          File.read!(path)
        )
      end)
      |> Enum.map(&Path.relative_to(&1, @root))

    assert violations == [], "Unreviewed native OS signal implementation: #{inspect(violations)}"
  end

  test "the guard catches command wrappers, executable lookup, shell signals and retired APIs" do
    for source <- [
          ~s|System.cmd("/bin/kill", ["-9", pid])|,
          ~s|NativeProcess.cmd("kill", ["-TERM", pid])|,
          ~s|cleanup_command("pkill", ["-P", pid], 4096)|,
          ~s|System.find_executable("taskkill")|,
          ~s|:os.cmd('kill -9 123')|,
          ~s|:exec.kill(pid, :sigkill)|,
          ~s|ProcessGroup.signal_workload_group(identity, :sigkill)|,
          ~s|BashExecutor.kill_process_tree(pid)|
        ] do
      assert [_ | _] = signal_calls(source)
    end

    assert [] = signal_calls(~s|ProcessGroup.terminate(pid, signal: :sigkill)|)
    assert [] = signal_calls(~s|Process.exit(pid, :kill)|)
    assert [] = signal_calls(~s|ProcessManager.kill(id, :sigterm)|)
  end

  test "non-termination exceptions cannot authorize a kill in the same module" do
    kernel = "apps/coding_agent/lib/coding_agent/eval/kernel.ex"
    probe = "apps/lemon_core/lib/lemon_core/secrets/lock.ex"
    launchd = "apps/lemon_core/lib/lemon_core/service/launchd.ex"

    assert allowed_source?(kernel, ~s|System.cmd("/bin/kill", ["-INT", "--", target], [])|)
    refute allowed_source?(kernel, ~s|System.cmd("/bin/kill", ["-KILL", "--", target], [])|)
    assert allowed_source?(probe, ~s|System.cmd("kill", ["-0", pid], [])|)
    refute allowed_source?(probe, ~s|System.cmd("kill", ["-TERM", pid], [])|)

    assert allowed_source?(
             launchd,
             ~s|Command.ok("launchctl", ["kill", "SIGTERM", target], opts)|
           )

    refute allowed_source?(launchd, ~s|Command.ok("kill", ["-TERM", pid], opts)|)
  end

  defp signal_calls(source) do
    {_ast, calls} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., _, [module, function]}, meta, args} = call, acc when is_list(args) ->
          forbidden =
            function in @retired or kill_command?(args) or
              (module in [:os, :exec, :erlexec] and function in [:kill, :killpg]) or
              (module == :os and function == :cmd and shell_signal?(args))

          {call, if(forbidden, do: [{meta[:line], call} | acc], else: acc)}

        {function, meta, args} = call, acc when is_atom(function) and is_list(args) ->
          {call,
           if(function in @retired or kill_command?(args),
             do: [{meta[:line], call} | acc],
             else: acc
           )}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp kill_command?([executable | args]) when is_binary(executable) do
    Path.basename(executable) in @kill_commands or
      (Path.basename(executable) == "launchctl" and match?([["kill" | _] | _], args))
  end

  defp kill_command?(_args), do: false

  defp shell_signal?([command | _]) when is_binary(command) or is_list(command),
    do: Regex.match?(~r/\b(?:kill|pkill|killall|taskkill)\b/, to_string(command))

  defp shell_signal?(_args), do: false

  # SIGINT interrupts a reusable eval cell; it is not teardown. A TERM/KILL
  # added beside it is still rejected, as are new executable lookup helpers.
  defp allowed_call?(
         "apps/coding_agent/lib/coding_agent/eval/kernel.ex",
         {{:., _, [{:__aliases__, _, [:System]}, :cmd]}, _,
          ["/bin/kill", ["-INT", "--", _target], _opts]}
       ),
       do: true

  # Signal zero probes lock-owner liveness without terminating anything.
  defp allowed_call?(
         "apps/lemon_core/lib/lemon_core/secrets/lock.ex",
         {{:., _, [{:__aliases__, _, [:System]}, :cmd]}, _, ["kill", ["-0", _pid], _opts]}
       ),
       do: true

  # launchd owns this service identity and its lifecycle; this is an OS service
  # manager request, not another workload PID/group termination implementation.
  defp allowed_call?(
         "apps/lemon_core/lib/lemon_core/service/launchd.ex",
         {{:., _, [{:__aliases__, _, [:Command]}, :ok]}, _,
          ["launchctl", ["kill", "SIGTERM", _target], _opts]}
       ),
       do: true

  defp allowed_call?(_path, _call), do: false

  defp allowed_source?(path, source), do: allowed_call?(path, Code.string_to_quoted!(source))
end
