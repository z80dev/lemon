defmodule LemonRouter.RoutingFeedbackSelectionTest do
  @moduledoc """
  Routing feedback must never silently override the operator's configured
  default model, is off unless enabled, and is read without a TOML parse per
  submission. Submissions are built by the real `SubmissionBuilder` against
  the application's `RoutingFeedbackStore` and a temporary global config.
  """
  use ExUnit.Case, async: false

  alias LemonMemory.TaskFingerprint
  alias LemonRouter.{RoutingFeedbackStore, SubmissionBuilder}

  @moduletag :tmp_dir
  @prompt "fix the bug in the parser"

  setup %{tmp_dir: tmp} do
    global = Path.join(tmp, "home/.lemon/config.toml")
    workspace = Path.join(tmp, "workspace")
    File.mkdir_p!(Path.dirname(global))
    File.mkdir_p!(workspace)

    saved_paths = Application.get_env(:lemon_core, :paths)
    saved_env = System.get_env("LEMON_FEATURE_ROUTING_FEEDBACK")
    Application.put_env(:lemon_core, :paths, global_config: global)
    System.delete_env("LEMON_FEATURE_ROUTING_FEEDBACK")

    on_exit(fn ->
      if saved_paths,
        do: Application.put_env(:lemon_core, :paths, saved_paths),
        else: Application.delete_env(:lemon_core, :paths)

      if saved_env, do: System.put_env("LEMON_FEATURE_ROUTING_FEEDBACK", saved_env)
      LemonCore.Config.reload()
    end)

    %{global: global, workspace: workspace}
  end

  test "an operator's changed default model wins over history for the old one", ctx do
    configure(ctx, "openai:model-a", "on")
    record(ctx, "model-a", success: 5)
    assert resolved_model(ctx) == "openai:model-a"

    configure(ctx, "openai:model-b", "on")
    assert resolved_model(ctx) == "openai:model-b"
  end

  test "history replaces a default only when the default measured worse here", ctx do
    configure(ctx, "openai:model-b", "on")
    record(ctx, "model-b", failure: 5)
    record(ctx, "model-c", success: 5)

    assert resolved_model(ctx) == "model-c"
  end

  test "routing feedback is off by default and history is then never consulted", ctx do
    configure(ctx, "openai:model-b", nil)
    record(ctx, "model-b", failure: 5)
    record(ctx, "model-c", success: 5)

    refute LemonCore.Config.cached().features.routing_feedback in [:on, :"default-on"]

    {model, calls} = traced(fn -> resolved_model(ctx) end)
    assert model == "openai:model-b"
    refute {RoutingFeedbackStore, :best_model_for_context} in calls
  end

  test "a submission reads the config cache, never a TOML parse", ctx do
    configure(ctx, "openai:model-b", "on")

    {model, calls} = traced(fn -> resolved_model(ctx) end)
    assert model == "openai:model-b"
    assert {RoutingFeedbackStore, :best_model_for_context} in calls

    refute Enum.any?(
             calls,
             &match?({LemonCore.Config.Modular, f} when f in [:load, :load_with_layers], &1)
           )
  end

  defp configure(ctx, default_model, routing_feedback) do
    features =
      if routing_feedback, do: "\n[features]\nrouting_feedback = \"#{routing_feedback}\"\n"

    File.write!(ctx.global, """
    [defaults]
    provider = "openai"
    model = "#{default_model}"
    #{features}
    """)

    LemonCore.Config.reload()
  end

  defp record(ctx, model, outcomes) do
    key = context_key(ctx) <> "|openai|" <> model

    for {outcome, count} <- outcomes, _ <- 1..count do
      GenServer.cast(RoutingFeedbackStore, {:record, key, Atom.to_string(outcome), nil})
    end

    :sys.get_state(RoutingFeedbackStore)
  end

  defp context_key(ctx) do
    TaskFingerprint.context_key(%TaskFingerprint{
      task_family: TaskFingerprint.classify_prompt(@prompt),
      workspace_key: ctx.workspace
    })
  end

  defp resolved_model(ctx) do
    request =
      LemonCore.RunRequest.new(%{
        origin: :control_plane,
        session_key: "agent:default:routing-feedback:#{System.unique_integer([:positive])}",
        agent_id: "default",
        prompt: @prompt,
        cwd: ctx.workspace,
        run_id: "run_#{System.unique_integer([:positive])}"
      })

    assert {:ok, submission} =
             SubmissionBuilder.build(request, %{
               run_supervisor: LemonRouter.RunSupervisor,
               run_process_module: LemonRouter.RunProcess,
               run_process_opts: %{}
             })

    submission.execution_request.meta.model
  end

  # Runs `fun` in a fresh process and returns its result with the traced
  # `{module, function}` calls it made.
  defp traced(fun) do
    parent = self()

    patterns = [
      {RoutingFeedbackStore, :best_model_for_context, :_},
      {LemonCore.Config.Modular, :_, :_}
    ]

    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:global]))

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go -> send(parent, {:traced_result, fun.()})
        end
      end)

    try do
      :erlang.trace(pid, true, [:call, {:tracer, parent}])
      send(pid, :go)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 10_000
      assert_received {:traced_result, result}
      ref = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, ^pid, ^ref}
      {result, collect_calls(pid, [])}
    after
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:global]))
    end
  end

  defp collect_calls(pid, calls) do
    receive do
      {:trace, ^pid, :call, {module, function, _args}} ->
        collect_calls(pid, [{module, function} | calls])
    after
      0 -> calls
    end
  end
end
