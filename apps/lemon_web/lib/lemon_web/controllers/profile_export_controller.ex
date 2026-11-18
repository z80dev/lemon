defmodule LemonWeb.ProfileExportController do
  @moduledoc """
  Downloads a profile's portable, credential-safe export.

  The `profiles.export` method (`LemonWeb.Rpc`) writes to a destination file;
  the controller exports into a private temporary file, streams it as an
  attachment and removes it. The managed home path and the temporary path
  never reach the response.
  """

  use LemonWeb, :controller

  alias LemonWeb.Rpc

  @id_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/

  def show(conn, %{"id" => id}) do
    if Regex.match?(@id_regex, id), do: export(conn, id), else: not_found(conn)
  end

  defp export(conn, id) do
    dir = Path.join(System.tmp_dir!(), "lemon-web-profile-export-#{random_suffix()}")
    destination = Path.join(dir, "#{id}.json")

    try do
      with :ok <- File.mkdir_p(dir),
           :ok <- File.chmod(dir, 0o700),
           {:ok, _result} <- Rpc.call("profiles.export", %{"id" => id, "path" => destination}),
           {:ok, content} <- File.read(destination) do
        send_download(conn, {:binary, content},
          filename: "lemon-profile-#{id}.json",
          content_type: "application/json"
        )
      else
        {:error, %{code: :not_found}} -> not_found(conn)
        _ -> unavailable(conn)
      end
    rescue
      _ -> unavailable(conn)
    after
      File.rm_rf(dir)
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> text("Profile not found")

  defp unavailable(conn),
    do: conn |> put_status(:service_unavailable) |> text("Profile export is unavailable")

  defp random_suffix, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
