defmodule LemonBrowser.SessionProviders.BrowserUse do
  @moduledoc "Browser Use Cloud session provider."

  @behaviour LemonBrowser.SessionProvider

  alias LemonBrowser.SessionProviders.Helpers

  @default_base_url "https://api.browser-use.com/api/v3"

  @impl true
  def id, do: :browser_use

  @impl true
  def available?, do: is_binary(Helpers.secret("BROWSER_USE_API_KEY"))

  @impl true
  def available?(opts), do: match?({:ok, _config}, resolve_config(opts))

  @impl true
  def create_session(_scope, opts) do
    with {:ok, config} <- resolve_config(opts) do
      request = Keyword.get(opts, :http_post, &Req.post/2)

      result =
        request.(config.base_url <> "/browsers",
          headers: headers(config.api_key),
          json: %{},
          connect_options: [timeout: 30_000],
          receive_timeout: 30_000
        )

      case result do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          body = Helpers.response_body(response)
          session_id = Helpers.normalize(body["id"])
          endpoint = Helpers.normalize(body["cdpUrl"] || body["connectUrl"])

          if session_id && endpoint do
            {:ok,
             %{
               id: session_id,
               cdp_endpoint: endpoint,
               expires_at: Helpers.normalize(body["timeoutAt"]),
               features: %{browser_use: true}
             }}
          else
            {:error, "Browser Use create response omitted id or CDP endpoint"}
          end

        other ->
          Helpers.request_error("Browser Use", "create", other)
      end
    end
  end

  @impl true
  def close_session(session_id, opts) do
    with {:ok, config} <- resolve_config(opts) do
      request = Keyword.get(opts, :http_patch, &Req.patch/2)

      case request.(config.base_url <> "/browsers/" <> URI.encode(session_id),
             headers: headers(config.api_key),
             json: %{"action" => "stop"},
             receive_timeout: 10_000
           ) do
        {:ok, %Req.Response{status: status}} when status in [200, 201, 204] -> :ok
        other -> Helpers.request_error("Browser Use", "close", other)
      end
    end
  end

  @impl true
  def status, do: %{provider: "browser_use", configured: available?(), transport: "cdp"}

  defp resolve_config(opts) do
    api_key =
      Helpers.config(opts, :api_key) |> Helpers.normalize() ||
        Helpers.secret("BROWSER_USE_API_KEY")

    if api_key do
      {:ok,
       %{
         api_key: api_key,
         base_url: Helpers.base_url(Helpers.config(opts, :base_url), @default_base_url)
       }}
    else
      {:error, :missing_browser_use_api_key}
    end
  end

  defp headers(api_key) do
    [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"x-browser-use-api-key", api_key}
    ]
  end
end
