defmodule LemonGateway.EngineSessionClaimTest do
  use ExUnit.Case, async: false

  alias LemonGateway.EngineSessionClaim
  import LemonPlatformTest.Testing.AsyncHelpers, only: [assert_eventually: 1]

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  test "a second owner fails immediately without queuing" do
    key = {:resume, make_ref()}
    assert :ok = EngineSessionClaim.claim(key)
    task = Task.async(fn -> EngineSessionClaim.claim(key) end)
    assert Task.await(task, 500) == {:error, :session_in_use}
    assert [{owner, _}] = Registry.lookup(LemonGateway.RunRegistry, {:engine_session, key})
    assert owner == self()
    assert :ok = EngineSessionClaim.release(key)
    assert :ok = EngineSessionClaim.release(key)
  end

  for reason <- [:normal, :killed, :cancelled] do
    test "owner exit #{reason} releases its claim" do
      key = {:session, make_ref()}
      observer = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          :ok = EngineSessionClaim.claim(key)
          send(observer, :claimed)

          receive do
            :finish -> exit(unquote(reason))
          end
        end)

      assert_receive :claimed
      assert {:error, :session_in_use} = EngineSessionClaim.claim(key)
      send(pid, :finish)
      assert_receive {:DOWN, ^monitor, :process, ^pid, unquote(reason)}

      assert_eventually(fn ->
        Registry.lookup(LemonGateway.RunRegistry, {:engine_session, key}) == []
      end)

      assert :ok = EngineSessionClaim.claim(key)
      assert :ok = EngineSessionClaim.release(key)
    end
  end

  test "release from a different process cannot displace a live owner" do
    key = {:resume, make_ref()}
    assert :ok = EngineSessionClaim.claim(key)
    task = Task.async(fn -> EngineSessionClaim.release(key) end)
    assert :ok = Task.await(task)
    task = Task.async(fn -> EngineSessionClaim.claim(key) end)
    assert {:error, :session_in_use} = Task.await(task)
    assert :ok = EngineSessionClaim.release(key)
  end
end
