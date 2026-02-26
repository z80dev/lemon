defmodule LemonCore.EventBridgeTest do
  use ExUnit.Case, async: false

  alias LemonCore.EventBridge

  defmodule ImplA do
    @moduledoc false
    def subscribe_run(run_id), do: send(self(), {:impl_a_subscribe, run_id})
    def unsubscribe_run(run_id), do: send(self(), {:impl_a_unsubscribe, run_id})
  end

  defmodule ImplB do
    @moduledoc false
    def subscribe_run(run_id), do: send(self(), {:impl_b_subscribe, run_id})
    def unsubscribe_run(run_id), do: send(self(), {:impl_b_unsubscribe, run_id})
  end

  defmodule ImplNoFunctions do
    @moduledoc false
    # This module deliberately does not export subscribe_run or unsubscribe_run
  end

  defmodule ImplRaises do
    @moduledoc false
    def subscribe_run(_run_id), do: raise("boom")
    def unsubscribe_run(_run_id), do: raise("boom")
  end

  setup do
    original = Application.get_env(:lemon_core, :event_bridge_impl)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:lemon_core, :event_bridge_impl)
        value -> Application.put_env(:lemon_core, :event_bridge_impl, value)
      end
    end)

    :ok
  end

  test "dispatches subscribe/unsubscribe to configured implementation" do
    :ok = EventBridge.configure(ImplA)

    assert :ok = EventBridge.subscribe_run("run_sub_1")
    assert_receive {:impl_a_subscribe, "run_sub_1"}

    assert :ok = EventBridge.unsubscribe_run("run_sub_1")
    assert_receive {:impl_a_unsubscribe, "run_sub_1"}
  end

  test "configure_guarded/1 rejects conflicting overwrite" do
    :ok = EventBridge.configure(ImplA)

    assert {:error, {:already_configured, ImplA}} = EventBridge.configure_guarded(ImplB)

    assert :ok = EventBridge.subscribe_run("run_guarded")
    assert_receive {:impl_a_subscribe, "run_guarded"}
    refute_receive {:impl_b_subscribe, "run_guarded"}
  end

  test "if_unset mode allows idempotent configure with same module" do
    :ok = EventBridge.configure(ImplA)
    assert :ok = EventBridge.configure(ImplA, mode: :if_unset)
  end

  test "subscribe_run and unsubscribe_run are no-ops when no impl is configured" do
    Application.delete_env(:lemon_core, :event_bridge_impl)

    assert :ok = EventBridge.subscribe_run("run_noop")
    refute_receive {:impl_a_subscribe, "run_noop"}
    refute_receive {:impl_b_subscribe, "run_noop"}

    assert :ok = EventBridge.unsubscribe_run("run_noop")
    refute_receive {:impl_a_unsubscribe, "run_noop"}
    refute_receive {:impl_b_unsubscribe, "run_noop"}
  end

  test "configure with nil clears impl so dispatching becomes a no-op" do
    :ok = EventBridge.configure(ImplA)
    assert :ok = EventBridge.subscribe_run("run_clear_1")
    assert_receive {:impl_a_subscribe, "run_clear_1"}

    :ok = EventBridge.configure(nil)

    assert :ok = EventBridge.subscribe_run("run_clear_2")
    refute_receive {:impl_a_subscribe, "run_clear_2"}

    assert :ok = EventBridge.unsubscribe_run("run_clear_2")
    refute_receive {:impl_a_unsubscribe, "run_clear_2"}
  end

  test "replace mode overwrites previously configured impl" do
    :ok = EventBridge.configure(ImplA)
    assert :ok = EventBridge.subscribe_run("run_replace_1")
    assert_receive {:impl_a_subscribe, "run_replace_1"}

    :ok = EventBridge.configure(ImplB, mode: :replace)

    assert :ok = EventBridge.subscribe_run("run_replace_2")
    assert_receive {:impl_b_subscribe, "run_replace_2"}
    refute_receive {:impl_a_subscribe, "run_replace_2"}

    assert :ok = EventBridge.unsubscribe_run("run_replace_2")
    assert_receive {:impl_b_unsubscribe, "run_replace_2"}
    refute_receive {:impl_a_unsubscribe, "run_replace_2"}
  end

  test "if_unset mode with nil returns error when already configured" do
    :ok = EventBridge.configure(ImplA)

    assert {:error, :already_configured} = EventBridge.configure(nil, mode: :if_unset)

    # Original impl should still be in place
    assert :ok = EventBridge.subscribe_run("run_if_unset_nil")
    assert_receive {:impl_a_subscribe, "run_if_unset_nil"}
  end

  test "invalid mode returns error tuple" do
    assert {:error, {:invalid_mode, :garbage}} =
             EventBridge.configure(ImplA, mode: :garbage)

    assert {:error, {:invalid_mode, :garbage}} =
             EventBridge.configure(nil, mode: :garbage)
  end

  test "dispatch handles module without subscribe_run/unsubscribe_run gracefully" do
    :ok = EventBridge.configure(ImplNoFunctions)

    assert :ok = EventBridge.subscribe_run("run_missing_fn")
    assert :ok = EventBridge.unsubscribe_run("run_missing_fn")
  end

  test "dispatch handles module that raises gracefully" do
    :ok = EventBridge.configure(ImplRaises)

    assert :ok = EventBridge.subscribe_run("run_raises")
    assert :ok = EventBridge.unsubscribe_run("run_raises")
  end
end
