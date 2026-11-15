defmodule LemonChannels.Adapters.WhatsApp.ModelPolicyAdapterTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.WhatsApp.ModelPolicyAdapter

  @table :whatsapp_session_models

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_channels)
    :ok
  end

  test "the application owns session overrides after a short-lived caller exits" do
    owner = Process.whereis(ModelPolicyAdapter)
    assert :ets.info(@table, :owner) == owner

    assert Enum.any?(Supervisor.which_children(LemonChannels.Supervisor), fn
             {ModelPolicyAdapter, ^owner, :worker, _} -> true
             _ -> false
           end)

    session_key = "whatsapp-model-owner"
    on_exit(fn -> :ets.delete(@table, {:model, session_key}) end)
    :ok = :sys.suspend(owner)

    try do
      {caller, monitor} =
        spawn_monitor(fn ->
          :ok = ModelPolicyAdapter.session_put(session_key, "provider/model")
        end)

      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
      assert :ets.info(@table, :owner) == owner
      assert ModelPolicyAdapter.session_get(session_key) == "provider/model"
    after
      :sys.resume(owner)
    end
  end

  test "only supervision creates the table and owner restart clears volatile overrides" do
    session_key = "whatsapp-model-restart"
    :ok = ModelPolicyAdapter.session_put(session_key, "provider/model")
    old_table = :ets.whereis(@table)
    :ok = Supervisor.terminate_child(LemonChannels.Supervisor, ModelPolicyAdapter)

    try do
      assert :ets.whereis(@table) == :undefined
      assert_raise ArgumentError, fn -> ModelPolicyAdapter.session_get(session_key) end

      assert_raise ArgumentError, fn ->
        ModelPolicyAdapter.session_put(session_key, "provider/other")
      end

      assert :ets.whereis(@table) == :undefined
    after
      {:ok, _} = Supervisor.restart_child(LemonChannels.Supervisor, ModelPolicyAdapter)
    end

    assert :ets.whereis(@table) != old_table
    assert :ets.info(@table, :owner) == Process.whereis(ModelPolicyAdapter)
    assert ModelPolicyAdapter.session_get(session_key) == nil
    assert :ok = ModelPolicyAdapter.session_put(session_key, "provider/reloaded")
    assert ModelPolicyAdapter.session_get(session_key) == "provider/reloaded"
    :ets.delete(@table, {:model, session_key})
  end
end
