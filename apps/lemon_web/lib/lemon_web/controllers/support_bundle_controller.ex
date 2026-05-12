defmodule LemonWeb.SupportBundleController do
  @moduledoc false

  use LemonWeb, :controller

  alias LemonCore.Doctor
  alias LemonCore.Doctor.SupportBundle

  def download(conn, _params) do
    bundle_path =
      Path.join(
        System.tmp_dir!(),
        "lemon-web-support-bundle-#{System.unique_integer([:positive, :monotonic])}.zip"
      )

    report = Doctor.report(project_dir: File.cwd!())

    with {:ok, path} <- SupportBundle.write(report, bundle_path: bundle_path),
         {:ok, binary} <- File.read(path) do
      File.rm(path)

      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_download({:binary, binary},
        filename: Path.basename(path),
        content_type: "application/zip"
      )
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(500, "Failed to generate support bundle")
    end
  end
end
