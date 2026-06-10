defmodule LemonSimUi.VendingBenchLaunchController do
  use LemonSimUi, :controller

  alias LemonSimUi.VendingBenchLauncher

  def create(conn, params) do
    preset_id = params["preset_id"] || params["model_preset"]

    case VendingBenchLauncher.start(preset_id) do
      {:ok, sim_id} ->
        redirect(conn, to: ~p"/watch/#{sim_id}")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Could not start VendingBench: #{inspect(reason)}")
        |> redirect(to: ~p"/")
    end
  end
end
