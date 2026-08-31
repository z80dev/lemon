defmodule LemonControlPlane.Methods.LearnTest do
  use ExUnit.Case, async: false

  alias LemonMemory.Store
  alias LemonControlPlane.Methods.{LearnConfirm, LearnReview, Registry}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(root)
    name = String.to_atom("cp_learn_#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: name, path: Path.join(tmp_dir, "memory")})

    old = Application.get_env(:lemon_control_plane, :learn_opts)

    Application.put_env(:lemon_control_plane, :learn_opts,
      root: root,
      global: false,
      memory_server: name,
      agent_id: "operator",
      now_ms: 1_700_000_000_000
    )

    on_exit(fn ->
      if old,
        do: Application.put_env(:lemon_control_plane, :learn_opts, old),
        else: Application.delete_env(:lemon_control_plane, :learn_opts)
    end)

    {:ok, root: root, memory_server: name}
  end

  test "authenticated methods review then confirm without returning source text", %{
    root: root,
    memory_server: memory_server
  } do
    planted = "sk-abcdefghijklmnopqrstuvwxyz123456"

    File.write!(
      Path.join(root, "guide.md"),
      "token=#{planted}\n" <> String.duplicate("Safe procedure step. ", 12)
    )

    assert LearnReview.name() == "learn.review"
    assert LearnReview.scopes() == [:read]
    assert LearnConfirm.scopes() == [:admin]
    assert {:ok, LearnReview} = Registry.lookup("learn.review")
    assert {:ok, LearnConfirm} = Registry.lookup("learn.confirm")

    params = %{
      "references" => ["@file:guide.md"],
      "project" => true,
      "agentId" => "operator"
    }

    assert {:ok, review} = LearnReview.handle(params, %{})
    wire = Jason.encode!(review)
    refute wire =~ planted
    refute wire =~ root
    refute wire =~ "Safe procedure step"

    read_ctx = %{
      conn_id: "learn-auth-test",
      conn_pid: self(),
      auth: %{role: :operator, scopes: [:read], token: nil, client_id: nil, identity: nil}
    }

    assert {:error, {:forbidden, "Insufficient permissions for learn.confirm"}} =
             Registry.dispatch(
               "learn.confirm",
               Map.put(params, "confirmationDigest", review["confirmationDigest"]),
               read_ctx
             )

    assert {:error, {:conflict, _}} =
             LearnConfirm.handle(
               Map.put(params, "confirmationDigest", String.duplicate("0", 64)),
               %{}
             )

    assert {:ok, confirmed} =
             LearnConfirm.handle(
               Map.put(params, "confirmationDigest", review["confirmationDigest"]),
               %{}
             )

    assert confirmed["status"] == "confirmed"
    assert [_doc] = Store.get_by_session(memory_server, "agent:operator:learn", limit: 10)
    refute Jason.encode!(confirmed) =~ planted
  end
end
