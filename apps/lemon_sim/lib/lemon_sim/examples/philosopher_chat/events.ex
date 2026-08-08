defmodule LemonSim.Examples.PhilosopherChat.Events do
  @moduledoc false

  alias LemonSim.Kernel.Event

  @spec normalize(Event.t() | map() | keyword()) :: Event.t()
  def normalize(raw_event), do: Event.new(raw_event)

  @doc "A participant posts a message to the thread."
  @spec message_posted(String.t(), String.t()) :: Event.t()
  def message_posted(author, text) do
    Event.new("message_posted", %{
      "author" => author,
      "text" => text
    })
  end

  @doc "Thread lifecycle status change."
  @spec status_changed(String.t()) :: Event.t()
  def status_changed(status) do
    Event.new("status_changed", %{"status" => status})
  end
end
