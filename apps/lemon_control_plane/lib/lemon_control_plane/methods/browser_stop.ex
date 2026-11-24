defmodule LemonControlPlane.Methods.BrowserStop do
  @moduledoc """
  Stops the local browser driver (`local`, `relay` and `cdp` providers) and
  the Chrome it launched. A browser it only attached to keeps running. The
  next browser request starts a fresh driver with the current configuration.
  """
  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "browser.stop"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) when params == %{} or is_nil(params) do
    case LemonBrowser.stop_local_driver() do
      :ok ->
        {:ok, %{"stopped" => true}}

      {:error, _reason} ->
        {:error,
         {:timeout,
          "The local browser driver did not confirm it stopped; check it before retrying.", nil}}
    end
  end

  def handle(_, _), do: {:error, {:invalid_request, "browser.stop expects an empty object.", nil}}
end
