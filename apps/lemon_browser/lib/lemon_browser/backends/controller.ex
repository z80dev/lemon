defmodule LemonBrowser.Backends.Controller do
  @moduledoc "Authenticated browser-controller backend."

  @behaviour LemonBrowser.Backend

  alias LemonBrowser.ControllerBroker

  @impl true
  def id, do: :controller

  @impl true
  def available?, do: is_pid(Process.whereis(ControllerBroker))

  @impl true
  def request(method, args, timeout_ms, opts) do
    binding = %{
      controller_id: Keyword.get(opts, :controller_id),
      browser_profile_id: Keyword.get(opts, :browser_profile_id),
      session_id: Keyword.get(opts, :session_id),
      run_id: Keyword.get(opts, :run_id)
    }

    broker_opts = Keyword.take(opts, [:server])
    ControllerBroker.request(binding, method, args, timeout_ms, broker_opts)
  end

  @impl true
  def status(opts), do: ControllerBroker.status(Keyword.take(opts, [:server]))
end
