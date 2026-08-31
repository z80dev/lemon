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
    with {:ok, binding} <- exact_binding(opts) do
      broker_opts = Keyword.take(opts, [:server])
      ControllerBroker.request(binding, method, args, timeout_ms, broker_opts)
    end
  end

  @impl true
  def status(opts), do: ControllerBroker.status(Keyword.take(opts, [:server]))

  defp exact_binding(opts) do
    binding = %{
      controller_id: normalized_option(opts, :controller_id),
      browser_profile_id: normalized_option(opts, :browser_profile_id),
      session_id: normalized_option(opts, :session_id),
      run_id: normalized_option(opts, :run_id)
    }

    case Enum.find([:controller_id, :browser_profile_id, :session_id], &is_nil(binding[&1])) do
      nil -> {:ok, binding}
      key -> {:error, {:missing_browser_controller_binding, key}}
    end
  end

  defp normalized_option(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          normalized -> normalized
        end

      _other ->
        nil
    end
  end
end
