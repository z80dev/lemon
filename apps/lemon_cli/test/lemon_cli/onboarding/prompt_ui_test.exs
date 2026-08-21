defmodule LemonCli.Onboarding.PromptUITest do
  use ExUnit.Case, async: true

  alias LemonCli.Onboarding.PromptUI

  @options [
    %{label: "First", value: :first},
    %{label: "Second", value: :second},
    %{label: "Third", value: :third}
  ]

  test "blank input selects the configured default" do
    {io, messages} = io_for([""])

    assert {:ok, :second} =
             PromptUI.select(
               %{title: "Choose", options: @options, default_index: 1},
               io: io,
               force: true
             )

    assert "  2. Second (default)" in Agent.get(messages, & &1)
  end

  test "invalid input is explained and retried" do
    {io, messages} = io_for(["0", "third"])

    assert {:ok, :third} =
             PromptUI.select(%{title: "Choose", options: @options}, io: io, force: true)

    assert "Enter a number from 1 to 3, or q to cancel." in Agent.get(messages, & &1)
  end

  test "q cancels without selecting a value" do
    {io, _messages} = io_for(["q"])

    assert :cancel =
             PromptUI.select(%{title: "Choose", options: @options}, io: io, force: true)
  end

  test "closed input cancels instead of silently accepting the default" do
    {io, _messages} = io_for([])

    assert :cancel =
             PromptUI.select(%{title: "Choose", options: @options}, io: io, force: true)
  end

  defp io_for(responses) do
    responses = start_agent(responses)
    messages = start_agent([])

    io = %{
      info: fn message -> Agent.update(messages, &[message | &1]) end,
      prompt: fn _prompt -> Agent.get_and_update(responses, &pop_response/1) end
    }

    {io, messages}
  end

  defp start_agent(value) do
    start_supervised!(%{
      id: make_ref(),
      start: {Agent, :start_link, [fn -> value end]}
    })
  end

  defp pop_response([response | rest]), do: {response, rest}
  defp pop_response([]), do: {nil, []}
end
