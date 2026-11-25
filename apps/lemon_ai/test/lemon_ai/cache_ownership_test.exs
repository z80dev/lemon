defmodule LemonAi.CacheOwnershipTest do
  use ExUnit.Case, async: false

  alias LemonAi.Auth.Cache

  test "named application caches belong to supervised owners" do
    children = Supervisor.which_children(LemonAi.Supervisor)

    for {table, module} <- [
          {:lemon_ai_auth_cache, Cache},
          {:ai_model_cache, LemonAi.ModelCache},
          {:lemon_ai_omp_auth_broker, LemonAi.Auth.OmpAuthBroker}
        ] do
      owner = Process.whereis(module)
      assert is_pid(owner)
      assert :ets.info(table, :owner) == owner
      assert {module, owner, :worker, [module]} in children
    end

    assert :ets.info(LemonAi.CallDispatcher.Slots, :owner) ==
             Process.whereis(LemonAi.Supervisor)

    assert :ets.info(LemonAi.CallDispatcher, :owner) == Process.whereis(LemonAi.Supervisor)
    refute Process.whereis(LemonAi.CallDispatcher)
  end

  test "auth reads and writes bypass the owner mailbox and survive caller exit" do
    owner = Process.whereis(Cache)
    key = {__MODULE__, make_ref()}
    :ok = :sys.suspend(owner)

    try do
      task = Task.async(fn -> Cache.put(key, "cached-value") end)
      assert Task.await(task) == :ok
      monitor = Process.monitor(task.pid)
      assert_receive {:DOWN, ^monitor, :process, _, _}
      assert Cache.get(key) == "cached-value"
      assert Cache.delete(key) == :ok
      assert Cache.get(key) == nil
    after
      :sys.resume(owner)
      Cache.delete(key)
    end
  end

  test "auth cache restart loses entries, and downtime never creates a caller-owned table" do
    old_owner = Process.whereis(Cache)
    key = {__MODULE__, make_ref()}
    Cache.put(key, "before-restart")
    assert :ok = Supervisor.terminate_child(LemonAi.Supervisor, Cache)

    try do
      assert Cache.get(key) == nil
      assert Cache.put(key, "during-restart") == :ok
      assert Cache.delete(key) == :ok
      assert :ets.whereis(:lemon_ai_auth_cache) == :undefined
    after
      {:ok, _pid} = Supervisor.restart_child(LemonAi.Supervisor, Cache)
    end

    owner = Process.whereis(Cache)
    assert owner != old_owner
    assert :ets.info(:lemon_ai_auth_cache, :owner) == owner
    assert Cache.get(key) == nil
    assert Cache.put(key, "after-restart") == :ok
    assert Cache.get(key) == "after-restart"
    Cache.delete(key)
  end

  test "persistent_term writes are limited to explicit provider configuration" do
    source_root = Path.expand("../../lib", __DIR__)

    writes =
      source_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        ast = path |> File.read!() |> Code.string_to_quoted!()
        file = Path.relative_to(path, source_root)

        {_ast, {_function, writes}} =
          Macro.traverse(ast, {nil, []}, &collect_writes(&1, &2, file), fn
            {kind, _, _} = node, {_function, writes} when kind in [:def, :defp] ->
              {node, {nil, writes}}

            node, acc ->
              {node, acc}
          end)

        writes
      end)

    assert Enum.sort(writes) == [
             {"lemon_ai/provider_registry.ex", {:init, 0}, :put},
             {"lemon_ai/provider_registry.ex", {:mutate_providers, 1}, :put}
           ]
  end

  defp collect_writes({kind, _, [head | _]} = node, {_function, writes}, _file)
       when kind in [:def, :defp] do
    {node, {function_signature(head), writes}}
  end

  defp collect_writes(
         {{:., _, [:persistent_term, operation]}, _, _} = node,
         {function, writes},
         file
       )
       when operation in [:put, :erase] do
    {node, {function, [{file, function, operation} | writes]}}
  end

  defp collect_writes(node, acc, _file), do: {node, acc}

  defp function_signature({:when, _, [head | _]}), do: function_signature(head)
  defp function_signature({name, _, args}), do: {name, length(args || [])}
end
