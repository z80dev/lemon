defmodule LemonBrowser.SessionProviders.Firecrawl do
  @moduledoc "Firecrawl cloud browser session provider."

  @behaviour LemonBrowser.SessionProvider

  alias LemonBrowser.SessionProviders.Helpers

  @default_base_url "https://api.firecrawl.dev"

  @impl true
  def id, do: :firecrawl

  @impl true
  def available?, do: is_binary(Helpers.secret("FIRECRAWL_API_KEY"))

  @impl true
  def available?(opts), do: match?({:ok, _config}, resolve_config(opts))

  @impl true
  def create_session(_scope, opts) do
    with {:ok, config} <- resolve_config(opts) do
      request = Keyword.get(opts, :http_post, &Req.post/2)

      result =
        request.(config.base_url <> "/v2/browser",
          headers: headers(config.api_key),
          json: %{"ttl" => config.ttl_seconds},
          connect_options: [timeout: 30_000],
          receive_timeout: 30_000
        )

      case result do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          body = Helpers.response_body(response)
          session_id = Helpers.normalize(body["id"])
          endpoint = Helpers.normalize(body["cdpUrl"])

          if session_id && endpoint do
            {:ok,
             %{
               id: session_id,
               cdp_endpoint: endpoint,
               features: %{firecrawl: true, ttl_seconds: config.ttl_seconds}
             }}
          else
            {:error, "Firecrawl create response omitted id or CDP endpoint"}
          end

        other ->
          Helpers.request_error("Firecrawl", "create", other)
      end
    end
  end

  @impl true
  def close_session(session_id, opts) do
    with {:ok, config} <- resolve_config(opts) do
      request = Keyword.get(opts, :http_delete, &Req.delete/2)

      case request.(config.base_url <> "/v2/browser/" <> URI.encode(session_id),
             headers: headers(config.api_key),
             receive_timeout: 10_000
           ) do
        {:ok, %Req.Response{status: status}} when status in [200, 201, 204] -> :ok
        other -> Helpers.request_error("Firecrawl", "close", other)
      end
    end
  end

  @impl true
  def status, do: %{provider: "firecrawl", configured: available?(), transport: "cdp"}

  defp resolve_config(opts) do
    api_key =
      Helpers.config(opts, :api_key) |> Helpers.normalize() || Helpers.secret("FIRECRAWL_API_KEY")

    if api_key do
      ttl =
        Helpers.config(opts, :ttl_seconds, System.get_env("FIRECRAWL_BROWSER_TTL"))
        |> Helpers.positive_integer(300, 3_600)

      {:ok,
       %{
         api_key: api_key,
         base_url:
           Helpers.base_url(
             Helpers.config(opts, :base_url, System.get_env("FIRECRAWL_API_URL")),
             @default_base_url
           ),
         ttl_seconds: ttl
       }}
    else
      {:error, :missing_firecrawl_api_key}
    end
  end

  defp headers(api_key) do
    [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"authorization", "Bearer #{api_key}"}
    ]
  end
end
