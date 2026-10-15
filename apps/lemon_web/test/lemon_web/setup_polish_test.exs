defmodule LemonWeb.SetupPolishTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import LemonWeb.Test.OperatorAuth
  @endpoint LemonWeb.Endpoint

  setup :configure_operator_token

  alias LemonWeb.Chat.Setup

  test "a failed readiness query is distinct from incomplete setup and fails closed" do
    previous = Application.get_env(:lemon_web, :setup_readiness_fun)
    Application.put_env(:lemon_web, :setup_readiness_fun, fn -> raise "unavailable" end)

    on_exit(fn ->
      if previous do
        Application.put_env(:lemon_web, :setup_readiness_fun, previous)
      else
        Application.delete_env(:lemon_web, :setup_readiness_fun)
      end
    end)

    state = Setup.status()
    refute Setup.ready?(state)
    html = render_component(&Setup.gate/1, state: state)
    assert html =~ "Setup status could not be checked"
    assert html =~ ~s(href="/diagnostics")
    assert html =~ "Check again"
    refute html =~ "create the local Lemon config"
  end

  test "the mobile rail adds dialog semantics and removes them on close" do
    open = LemonWeb.Layouts.open_rail() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

    close =
      LemonWeb.Layouts.close_rail() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

    assert open =~ "aria-modal"
    assert open =~ "dialog"
    assert close =~ "remove_attr"
    assert close =~ "aria-modal"
  end

  test "active refresh failure is visible and clears on the next successful poll", %{conn: conn} do
    previous = Application.get_env(:lemon_web, :chat_rpc_stub)
    {:ok, state} = Agent.start_link(fn -> :error end)

    Application.put_env(:lemon_web, :chat_rpc_stub, fn
      "sessions.active.list", _ ->
        case Agent.get(state, & &1) do
          :error -> {:error, {:unavailable, "Unavailable", nil}}
          :ok -> {:ok, %{"sessions" => []}}
        end

      _, _ ->
        :passthrough
    end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_web, :chat_rpc_stub, previous),
        else: Application.delete_env(:lemon_web, :chat_rpc_stub)
    end)

    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#active-runs-unavailable", "Could not refresh active runs")
    assert has_element?(view, "#home-active-runs-unavailable")
    Agent.update(state, fn _ -> :ok end)
    send(view.pid, :poll)
    refute has_element?(view, "#active-runs-unavailable")
    refute has_element?(view, "#home-active-runs-unavailable")
  end
end
