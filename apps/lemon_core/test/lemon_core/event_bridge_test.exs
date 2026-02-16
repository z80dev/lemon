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
end
