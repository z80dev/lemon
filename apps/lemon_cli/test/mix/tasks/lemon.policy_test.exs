defmodule Mix.Tasks.Lemon.PolicyTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCore.PolicyStore
  alias Mix.Tasks.Lemon.Policy

  setup do
    Mix.Task.run("loadpaths")
    peer = Integer.to_string(System.unique_integer([:positive]))
    route = {"telegram", "default", peer, nil}
    on_exit(fn -> PolicyStore.delete_chat(route) end)
    %{peer: peer, route: route}
  end

  test "--peer without --account writes the route channel sessions read", ctx do
    capture_io(fn ->
      Policy.run(["set", "telegram", "--peer", ctx.peer, "--model", "openai:gpt-5"])
    end)

    session_key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :group,
        peer_id: ctx.peer
      })

    assert {:ok, %{model: "openai:gpt-5", model_route: route}} =
             PolicyStore.resolve_chat(session_key)

    assert route == ctx.route
  end

  test "--thread without --peer is refused" do
    assert_raise Mix.Error, ~r/--thread requires --peer/, fn ->
      Policy.run(["set", "telegram", "--thread", "7", "--model", "m"])
    end
  end

  test "thinking-only rows report no model", ctx do
    capture_io(fn ->
      Policy.run(["set", "telegram", "--peer", ctx.peer, "--thinking", "high"])
    end)

    output = capture_io(fn -> Policy.run(["get", "telegram", "--peer", ctx.peer]) end)

    assert output =~ "Model:    (none)"
    assert output =~ "Thinking: high"
  end

  test "setting a model preserves an existing thinking default", ctx do
    capture_io(fn ->
      Policy.run(["set", "telegram", "--peer", ctx.peer, "--thinking", "high"])
    end)

    capture_io(fn ->
      Policy.run(["set", "telegram", "--peer", ctx.peer, "--model", "openai:gpt-5"])
    end)

    assert {:ok, %{model: "openai:gpt-5", thinking_level: "high"}} =
             PolicyStore.fetch_chat(ctx.route)

    capture_io(fn -> Policy.run(["clear", "telegram", "--peer", ctx.peer]) end)
    assert PolicyStore.fetch_chat(ctx.route) == {:ok, nil}
  end
end
