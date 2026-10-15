defmodule LemonOmp.ConfigureTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  setup do
    use_fake_omp()
    ws = workspace!()
    key = "agent:omp-configure:#{System.unique_integer([:positive])}"
    {:ok, ws: ws, owner: %{kind: :agent, session_key: key}, scope: [owner: {:session_key, key}]}
  end

  defp start!(ctx, prompt \\ "HOLD configure") do
    assert {:ok, wire} =
             LemonOmp.start(
               %{cwd: ctx.ws, prompt: prompt, model: "fake/original", thinking: "high"},
               owner: ctx.owner
             )

    wire["id"]
  end

  defp configuration_commands(ws) do
    Enum.filter(received(ws), &(&1["type"] in ["set_model", "set_thinking_level", "get_state"]))
  end

  test "changes model then thinking during a turn without restarting or aborting", ctx do
    id = start!(ctx)
    pid = fake_pid(ctx.ws)

    assert {:ok, wire} =
             LemonOmp.configure(
               id,
               %{model: "openrouter/nvidia/cheap:free", thinking: "minimal"},
               ctx.scope
             )

    assert wire["id"] == id
    assert wire["status"] == "running"
    assert wire["model"] == "openrouter/nvidia/cheap:free"
    assert wire["thinking"] == "minimal"
    assert fake_pid(ctx.ws) == pid
    assert {:ok, ^wire} = LemonOmp.get(id, ctx.scope)

    assert [model, thinking, snapshot] = configuration_commands(ctx.ws)
    assert model["provider"] == "openrouter"
    assert model["modelId"] == "nvidia/cheap:free"
    assert thinking["type"] == "set_thinking_level"
    assert thinking["level"] == "minimal"
    assert snapshot["type"] == "get_state"
    assert length(Enum.uniq(Enum.map([model, thinking, snapshot], & &1["id"]))) == 3
    refute Enum.any?(received(ctx.ws), &(&1["type"] == "abort"))

    # The held call finishes with its old model receipt, not the selected one.
    assert {:ok, _} = LemonOmp.send_message(id, "finish now", :steer, ctx.scope)
    assert {:ok, settled, :settled} = LemonOmp.wait(id, 5_000, ctx.scope)
    assert settled["model"] == "openrouter/nvidia/cheap:free"
  end

  test "model-only idle switch reports omp's clamped thinking", ctx do
    id = start!(ctx, "finish first")
    assert {:ok, _, :settled} = LemonOmp.wait(id, 5_000, ctx.scope)

    assert {:ok, wire} = LemonOmp.configure(id, %{"model" => "fake/clamped"}, ctx.scope)
    assert wire["status"] == "idle"
    assert wire["model"] == "fake/clamped"
    assert wire["thinking"] == "low"
    assert Enum.map(configuration_commands(ctx.ws), & &1["type"]) == ["set_model", "get_state"]
  end

  test "thinking-only switch preserves the model and uses omp's effective level", ctx do
    id = start!(ctx)
    assert {:ok, wire} = LemonOmp.configure(id, %{thinking: "off"}, ctx.scope)
    assert wire["model"] == "fake/original"
    assert wire["thinking"] == "off"

    assert Enum.map(configuration_commands(ctx.ws), & &1["type"]) == [
             "set_thinking_level",
             "get_state"
           ]
  end

  test "a model without thinking clears the old snapshot level", ctx do
    id = start!(ctx)
    assert {:ok, wire} = LemonOmp.configure(id, %{model: "fake/no-thinking"}, ctx.scope)
    assert wire["thinking"] == nil
    assert {:ok, %{"thinking" => nil}} = LemonOmp.get(id, ctx.scope)
  end

  test "waits for correlated mutation acknowledgement and refreshed snapshot", ctx do
    put_app_env(:command_timeout_ms, 3_000)
    id = start!(ctx)
    File.write!(Path.join(ctx.ws, ".fake_omp_configure_gate"), "")
    File.write!(Path.join(ctx.ws, ".fake_omp_state_mode"), "gate")

    task =
      Task.async(fn ->
        LemonOmp.configure(id, %{model: "fake/cheap", thinking: "low"}, ctx.scope)
      end)

    wait_until(fn -> Enum.any?(configuration_commands(ctx.ws), &(&1["type"] == "set_model")) end)
    assert Task.yield(task, 20) == nil
    refute Enum.any?(configuration_commands(ctx.ws), &(&1["type"] == "set_thinking_level"))
    File.write!(Path.join(ctx.ws, ".fake_omp_configure_release"), "")
    wait_until(fn -> Enum.any?(configuration_commands(ctx.ws), &(&1["type"] == "get_state")) end)
    assert Task.yield(task, 20) == nil
    File.write!(Path.join(ctx.ws, ".fake_omp_state_release"), "")
    assert {:ok, %{"model" => "fake/cheap", "thinking" => "low"}} = Task.await(task)
  end

  test "rejects invalid or empty parameters before issuing any command", ctx do
    id = start!(ctx)

    for params <- [
          nil,
          [],
          %{},
          %{model: ""},
          %{thinking: nil},
          %{model: "unqualified"},
          %{model: "fake/"},
          %{model: "/model"},
          %{model: "bad model/name"},
          %{model: String.duplicate("x", 129)},
          %{model: 7},
          %{model: "fake/cheap", thinking: "ultra"},
          %{thinking: true}
        ] do
      assert {:error, :invalid_params} = LemonOmp.configure(id, params, ctx.scope)
    end

    assert configuration_commands(ctx.ws) == []
  end

  test "rejection stops the chain and sanitizes omp's error", ctx do
    id = start!(ctx)

    assert {:error, {:rejected, "Model refused"}} =
             LemonOmp.configure(id, %{model: "fake/REJECT", thinking: "low"}, ctx.scope)

    assert [%{"type" => "set_model"}] = configuration_commands(ctx.ws)
  end

  test "thinking rejection without earlier changes is a plain rejection", ctx do
    id = start!(ctx)
    File.write!(Path.join(ctx.ws, ".fake_omp_thinking_mode"), "reject")

    assert {:error, {:rejected, "Thinking refused"}} =
             LemonOmp.configure(id, %{thinking: "low"}, ctx.scope)
  end

  test "reports acknowledged model change if the second command is rejected", ctx do
    id = start!(ctx)
    File.write!(Path.join(ctx.ws, ".fake_omp_thinking_mode"), "reject")

    assert {:error, {:partially_applied, ["model"], "thinking", {:rejected, "Thinking refused"}}} =
             LemonOmp.configure(id, %{model: "fake/cheap", thinking: "low"}, ctx.scope)

    assert {:ok, %{"model" => "fake/cheap", "thinking" => "high"}} = LemonOmp.get(id, ctx.scope)

    assert Enum.map(configuration_commands(ctx.ws), & &1["type"]) == [
             "set_model",
             "set_thinking_level",
             "get_state"
           ]
  end

  test "MUTE is outcome_unknown and never retries or applies the next change", ctx do
    put_app_env(:command_timeout_ms, 200)
    id = start!(ctx, "MUTE")

    assert {:error, :outcome_unknown} =
             LemonOmp.configure(id, %{model: "fake/cheap", thinking: "low"}, ctx.scope)

    assert [%{"type" => "set_model"}] = configuration_commands(ctx.ws)
  end

  test "second-command silence reports only the acknowledged model as applied", ctx do
    put_app_env(:command_timeout_ms, 200)
    id = start!(ctx)
    File.write!(Path.join(ctx.ws, ".fake_omp_thinking_mode"), "mute")

    assert {:error, {:partially_applied, ["model"], "thinking", :outcome_unknown}} =
             LemonOmp.configure(id, %{model: "fake/cheap", thinking: "low"}, ctx.scope)

    assert Enum.map(configuration_commands(ctx.ws), & &1["type"]) == [
             "set_model",
             "set_thinking_level",
             "get_state"
           ]

    assert {:ok, %{"model" => "fake/cheap"}} = LemonOmp.get(id, ctx.scope)
  end

  test "snapshot silence reports acknowledged settings without claiming refreshed success", ctx do
    put_app_env(:command_timeout_ms, 200)
    id = start!(ctx)
    File.write!(Path.join(ctx.ws, ".fake_omp_state_mode"), "mute")

    assert {:error, {:partially_applied, ["model", "thinking"], "snapshot", :outcome_unknown}} =
             LemonOmp.configure(id, %{model: "fake/cheap", thinking: "low"}, ctx.scope)

    assert length(configuration_commands(ctx.ws)) == 3
  end

  test "snapshot rejection reports applied settings and the rejected refresh", ctx do
    id = start!(ctx)
    File.write!(Path.join(ctx.ws, ".fake_omp_state_mode"), "reject")

    assert {:error, {:partially_applied, ["thinking"], "snapshot", {:rejected, "State refused"}}} =
             LemonOmp.configure(id, %{thinking: "low"}, ctx.scope)
  end

  test "process exit between changes preserves the acknowledged model receipt", ctx do
    id = start!(ctx)
    File.write!(Path.join(ctx.ws, ".fake_omp_thinking_mode"), "exit")

    assert {:error, {:partially_applied, ["model"], "thinking", :not_running}} =
             LemonOmp.configure(id, %{model: "fake/cheap", thinking: "low"}, ctx.scope)
  end

  test "closed and foreign sessions fail closed without sending commands", ctx do
    id = start!(ctx)
    foreign = [owner: {:session_key, "another-conversation"}]
    assert {:error, :not_found} = LemonOmp.configure(id, %{thinking: "low"}, foreign)
    assert {:error, :not_found} = LemonOmp.configure("omp_missing", %{thinking: "low"}, ctx.scope)
    assert {:ok, _wire} = LemonOmp.close(id, ctx.scope)
    assert {:error, :not_running} = LemonOmp.configure(id, %{thinking: "low"}, ctx.scope)
    assert configuration_commands(ctx.ws) == []
  end
end
