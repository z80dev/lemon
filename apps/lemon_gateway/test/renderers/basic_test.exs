defmodule LemonGateway.Renderers.BasicTest do
  alias Elixir.LemonGateway, as: LemonGateway
  use ExUnit.Case, async: true

  alias Elixir.LemonGateway.Renderers.Basic
  alias Elixir.LemonGateway.Event
  alias LemonCore.ResumeToken

  defmodule BasicTestEngine do
    def format_resume(%ResumeToken{value: value}), do: "test resume #{value}"
  end

  test "init stores engine" do
    state = Basic.init(%{engine: __MODULE__.BasicTestEngine})
    assert state.engine == __MODULE__.BasicTestEngine
    assert state.resume_line == nil
  end

  test "started renders running with resume line" do
    token = %ResumeToken{engine: "test", value: "abc"}
    state = Basic.init(%{engine: __MODULE__.BasicTestEngine})

    {state, result} = Basic.apply_event(state, Event.started(%{engine: "test", resume: token}))

    assert {:render, %{text: text, status: :running}} = result
    assert String.contains?(text, "test resume abc")
    assert state.resume_line == "test resume abc"
  end

  test "completed includes resume line even if started not seen" do
    token = %ResumeToken{engine: "test", value: "xyz"}
    state = Basic.init(%{engine: __MODULE__.BasicTestEngine})

    {state, result} =
      Basic.apply_event(state, Event.completed(%{engine: "test", ok: true, answer: "ok", resume: token}))

    assert {:render, %{text: text, status: :done}} = result
    assert String.contains?(text, "test resume xyz")
    assert state.resume_line == "test resume xyz"
  end
end
