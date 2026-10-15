defmodule LemonControlPlane.Methods.LearningTimelineTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.Registry

  setup do
    previous = Application.fetch_env(:lemon_control_plane, :learning_timeline_fun)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lemon_control_plane, :learning_timeline_fun, value)
        :error -> Application.delete_env(:lemon_control_plane, :learning_timeline_fun)
      end
    end)

    :ok
  end

  test "registered read method delegates only bounded profile filters to the owner" do
    parent = self()
    payload = %{"items" => [], "limit" => 100, "history" => "current_state"}

    Application.put_env(:lemon_control_plane, :learning_timeline_fun, fn profile, opts ->
      send(parent, {:timeline, profile, opts})
      {:ok, payload}
    end)

    assert {:ok, ^payload} =
             call(%{
               "profileId" => "alice",
               "kind" => "skill",
               "limit" => 100,
               "workspaceDir" => "/caller-controlled-path"
             })

    assert_receive {:timeline, "alice", [kind: "skill", limit: 100]}
    assert {:ok, ^payload} = call(nil)
    assert_receive {:timeline, "default", [kind: "all", limit: 50]}
  end

  test "invalid filters and unauthorized principals never reach the read model" do
    Application.put_env(:lemon_control_plane, :learning_timeline_fun, fn _, _ ->
      flunk("rejected request reached the timeline")
    end)

    for params <- [
          %{"profileId" => "../alice"},
          %{"profileId" => String.duplicate("a", 65)},
          %{"profileId" => 42},
          %{"kind" => "unknown"},
          %{"limit" => 0},
          %{"limit" => 101},
          %{"limit" => "100"}
        ] do
      assert {:error, {:invalid_request, _}} = call(params)
    end

    assert {:error, {:unauthorized, _}} = call(%{}, %{})
    assert {:error, {:forbidden, _}} = call(%{}, Authorize.node_context("node-test"))

    assert {:error, {:forbidden, _}} =
             call(%{}, %{role: :operator, scopes: [:write], client_id: "writer"})
  end

  test "storage errors remain unavailable and never expose private failure details" do
    for fun <- [
          fn _, _ -> {:error, {:storage, "/private/token=secret"}} end,
          fn _, _ -> raise "private storage failure token=secret" end
        ] do
      Application.put_env(:lemon_control_plane, :learning_timeline_fun, fun)

      assert {:error, {:unavailable, "Learning timeline is unavailable"} = error} = call(%{})
      refute inspect(error) =~ "secret"
      refute inspect(error) =~ "/private"
    end
  end

  defp call(params, auth \\ %{role: :operator, scopes: [:read], client_id: "timeline-reader"}) do
    Registry.dispatch("learning.timeline", params, %{
      auth: auth,
      conn_id: "timeline-test",
      conn_pid: self()
    })
  end
end
