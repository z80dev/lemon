defmodule LemonRouter.ModelSelectionTest do
  use ExUnit.Case, async: false

  alias LemonRouter.ModelSelection

  setup do
    {started_here?, pid} =
      case Process.whereis(LemonGateway.EngineRegistry) do
        nil ->
          {:ok, started_pid} = LemonGateway.EngineRegistry.start_link([])
          {true, started_pid}

        existing_pid ->
          {false, existing_pid}
      end

    on_exit(fn ->
      if started_here? and is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid)
    end)

    :ok
  end

  test "model precedence: explicit > meta > session > profile > default" do
    resolved =
      ModelSelection.resolve(%{
        explicit_model: "explicit-model",
        meta_model: "meta-model",
        session_model: "session-model",
        profile_model: "profile-model",
        default_model: "default-model"
      })

    assert resolved.model == "explicit-model"

    resolved_2 =
      ModelSelection.resolve(%{
        explicit_model: nil,
        meta_model: nil,
        session_model: "session-model",
        profile_model: "profile-model",
        default_model: "default-model"
      })

    assert resolved_2.model == "session-model"
  end

  test "engine precedence: resume > explicit > model > profile" do
    assert "codex" ==
             ModelSelection.resolve(%{
               resume_engine: "codex",
               explicit_engine_id: "claude",
               explicit_model: "opencode:latest",
               profile_default_engine: "lemon"
             }).engine_id

    assert "claude" ==
             ModelSelection.resolve(%{
               explicit_engine_id: "claude",
               explicit_model: "codex:latest",
               profile_default_engine: "lemon"
             }).engine_id

    assert "codex:gpt-test" ==
             ModelSelection.resolve(%{
               explicit_model: "codex:gpt-test",
               profile_default_engine: "lemon"
             }).engine_id

    assert "lemon" ==
             ModelSelection.resolve(%{
               explicit_model: "openai:gpt-4.1",
               profile_default_engine: "lemon"
             }).engine_id
  end

  test "warns when explicit engine conflicts with model-implied engine" do
    resolved =
      ModelSelection.resolve(%{
        explicit_engine_id: "claude",
        explicit_model: "codex:gpt-5"
      })

    assert is_binary(resolved.warning)
    assert resolved.warning =~ "implies engine"
  end

  test "does not warn when explicit and model engine prefixes align" do
    resolved =
      ModelSelection.resolve(%{
        explicit_engine_id: "codex",
        explicit_model: "codex:gpt-5"
      })

    assert resolved.warning == nil
  end
end
