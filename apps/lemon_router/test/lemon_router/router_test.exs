defmodule LemonRouter.RouterTest do
  use ExUnit.Case, async: false

  alias LemonRouter.Router

  setup do
    start_if_needed(LemonRouter.RunRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.RunRegistry)
    end)

    start_if_needed(LemonRouter.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.SessionRegistry)
    end)

    :ok
  end

  defp start_if_needed(name, start_fn) do
    if is_nil(Process.whereis(name)) do
      {:ok, _} = start_fn.()
    end
  end

  defp start_registered_run(parent, session_key, run_id) do
    pid =
      spawn_link(fn ->
        _ = Registry.register(LemonRouter.RunRegistry, run_id, :ok)
        _ = Registry.register(LemonRouter.SessionRegistry, session_key, %{run_id: run_id})
        send(parent, {:registered, run_id, self()})

        receive do
          {:"$gen_cast", {:abort, reason}} ->
            send(parent, {:aborted, run_id, reason})
        after
          5_000 ->
            send(parent, {:abort_timeout, run_id})
        end
      end)

    pid
  end

  test "abort/2 aborts the active run registered for the session" do
    session_key = "agent:test:main"
    run_id1 = "run_#{System.unique_integer([:positive])}"

    _pid1 = start_registered_run(self(), session_key, run_id1)

    assert_receive {:registered, ^run_id1, _}

    Router.abort(session_key, :test_abort)

    assert_receive {:aborted, ^run_id1, :test_abort}
  end

  test "abort/2 is a no-op when session has no runs" do
    assert :ok = Router.abort("missing:session", :test_abort)
  end
end
