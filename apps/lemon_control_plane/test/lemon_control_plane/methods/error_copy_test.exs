defmodule LemonControlPlane.Methods.ErrorCopyTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods

  test "cron internal tuple failures remain internal and never expose terms" do
    with_failing_server(LemonAutomation.CronManager, fn _ -> true end, fn ->
      for {module, params} <- [
            {Methods.CronAdd, %{}},
            {Methods.CronAbort, %{"runId" => "test-run"}},
            {Methods.CronPause, %{"id" => "test-job"}},
            {Methods.CronRemove, %{"id" => "test-job"}},
            {Methods.CronResume, %{"id" => "test-job"}},
            {Methods.CronRun, %{"id" => "test-job"}},
            {Methods.CronUpdate, %{"id" => "test-job", "enabled" => false}}
          ] do
        assert {:error, {:internal_error, message, nil}} = module.handle(params, %{})
        assert_plain(message)
      end
    end)
  end

  test "missing cron fields are plain names and invalid request" do
    assert {:error, {:invalid_request, message, nil}} = Methods.CronAdd.handle(%{}, %{})
    assert message =~ "Missing required fields:"
    assert message =~ "name"
    assert message =~ "schedule"
    refute message =~ "["
    refute message =~ ":name"
    refute message =~ "{"
  end

  test "goal persistence tuple failures are internal errors with next steps" do
    key = "error-copy-goal-#{System.unique_integer([:positive])}"
    {:ok, _} = LemonAgent.Workspace.GoalStore.set(key, "test goal")

    try do
      with_failing_server(
        LemonCore.Store,
        fn
          {:generic_put, :goals, ^key, _} -> true
          {:generic_delete, :goals, ^key} -> true
          _ -> false
        end,
        fn ->
          for module <- [Methods.GoalPause, Methods.GoalResume, Methods.GoalClear] do
            assert {:error, {:internal_error, message, nil}} =
                     module.handle(%{"sessionKey" => key}, %{})

            assert_plain(message)
          end
        end
      )
    after
      LemonAgent.Workspace.GoalStore.clear(key)
    end
  end

  defp assert_plain(message) do
    assert message =~ "lemon doctor"
    refute message =~ "{"
    refute message =~ "%{"
    refute message =~ ":private"
  end

  # Forward unrelated traffic to the real server; only the selected requests fail.
  # Registration and the original process are restored even if an assertion fails.
  defp with_failing_server(name, fail?, fun) do
    original = Process.whereis(name)
    assert is_pid(original)
    proxy = spawn(fn -> proxy_loop(original, fail?) end)
    Process.unregister(name)
    Process.register(proxy, name)

    try do
      fun.()
    after
      Process.unregister(name)
      Process.register(original, name)
      Process.exit(proxy, :kill)
    end
  end

  defp proxy_loop(original, fail?) do
    receive do
      {:"$gen_call", from, request} = message ->
        if fail?.(request) do
          GenServer.reply(from, {:error, {:storage_failed, %{private: :detail}}})
        else
          send(original, message)
        end

        proxy_loop(original, fail?)

      message ->
        send(original, message)
        proxy_loop(original, fail?)
    end
  end
end
