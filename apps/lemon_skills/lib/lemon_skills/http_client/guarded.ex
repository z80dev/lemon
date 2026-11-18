defmodule LemonSkills.HttpClient.Guarded do
  @moduledoc """
  Default skill marketplace HTTP client, built on `LemonCore.Net.HTTP`.

  Every hop is authorized and pinned by the shared outbound policy: public
  destinations only, except the host of the operator-configured
  `config :lemon_skills, :registry_url`, which may be private. At most three
  redirects are followed, each re-authorized, with credentials dropped when
  the origin changes. Bodies are capped at 8 MiB while they stream and each
  hop has a 30 s deadline.
  """

  @behaviour LemonSkills.HttpClient

  alias LemonCore.Net.HTTP

  @timeout_ms 30_000
  @max_body_bytes 8 * 1024 * 1024
  @max_redirects 3

  @impl true
  def fetch(url, headers) do
    opts = [
      headers: headers,
      timeout_ms: @timeout_ms,
      max_body_bytes: @max_body_bytes,
      max_redirects: @max_redirects,
      allow_private_hosts: configured_hosts()
    ]

    case HTTP.request(:get, url, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp configured_hosts do
    with url when is_binary(url) <- Application.get_env(:lemon_skills, :registry_url),
         %URI{host: host} when is_binary(host) and host != "" <- URI.parse(url) do
      [host]
    else
      _ -> []
    end
  end
end
