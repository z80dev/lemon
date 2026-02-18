defmodule LemonPoker.Web.WSConnection do
  @moduledoc false

  @behaviour WebSock

  @topic LemonPoker.MatchServer.topic()

  @impl WebSock
  def init(_opts) do
    Phoenix.PubSub.subscribe(LemonCore.PubSub, @topic)
    send(self(), :send_snapshot)
    {:ok, %{}}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "ping"}} ->
        {:push, {:text, Jason.encode!(%{type: "pong"})}, state}

      _ ->
        {:ok, state}
    end
  end

  def handle_in({_data, _meta}, state), do: {:ok, state}

  @impl WebSock
  def handle_info(:send_snapshot, state) do
    payload = LemonPoker.MatchServer.snapshot()
    {:push, {:text, Jason.encode!(%{type: "snapshot", payload: payload})}, state}
  end

  def handle_info({:poker_event, event}, state) do
    {:push, {:text, Jason.encode!(%{type: "event", payload: event})}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state) do
    :ok
  end
end
