defmodule LemonEvals.PayloadProfileTest do
  use ExUnit.Case, async: false

  defmodule Recorder do
    use GenServer

    def start_link(owner),
      do: GenServer.start_link(__MODULE__, owner, name: LemonEvals.PayloadProfile)

    def init(owner), do: {:ok, owner}

    def handle_cast(packet, owner) do
      send(owner, packet)
      {:noreply, owner}
    end
  end

  test "observer attribution binds the executor parent run, not provider metadata" do
    start_supervised!({Recorder, self()})

    metadata = %{
      provider: :zai,
      model: "glm-5.3",
      session_id: "native-parent-session",
      run_id: "untrusted-other-run",
      authorization: "offline-fixture-private-header"
    }

    LemonEvals.PayloadProfile.record(:payload, "executor-parent-run", %{messages: []}, metadata)

    LemonEvals.PayloadProfile.record(
      :usage,
      "executor-parent-run",
      %{prompt_tokens: 100},
      metadata
    )

    for {event, data} <- [payload: %{messages: []}, usage: %{prompt_tokens: 100}] do
      assert_receive {:record, ^event, ^data,
                      %{
                        provider: :zai,
                        model: "glm-5.3",
                        session_id: "native-parent-session",
                        run_id: "executor-parent-run"
                      } = safe}

      refute Map.has_key?(safe, :authorization)
    end
  end
end
