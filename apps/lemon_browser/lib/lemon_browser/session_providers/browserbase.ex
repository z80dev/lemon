defmodule LemonBrowser.SessionProviders.Browserbase do
  @moduledoc "Browserbase cloud browser session provider."

  @behaviour LemonBrowser.SessionProvider

  alias LemonBrowser.SessionProviders.Helpers

  @default_base_url "https://api.browserbase.com"

  @impl true
  def id, do: :browserbase

  @impl true
  def available? do
    is_binary(Helpers.secret("BROWSERBASE_API_KEY")) and
      is_binary(Helpers.secret("BROWSERBASE_PROJECT_ID"))
  end

  @impl true
  def available?(opts), do: match?({:ok, _config}, resolve_config(opts))

  @impl true
  def create_session(_scope, opts) do
    with {:ok, config} <- resolve_config(opts) do
      request = Keyword.get(opts, :http_post, &Req.post/2)
      session_config = create_body(config)

      case create_with_feature_fallback(request, config, session_config) do
        {:ok, %Req.Response{status: status} = response, features} when status in 200..299 ->
          body = Helpers.response_body(response)
          session_id = Helpers.normalize(body["id"])
          endpoint = Helpers.normalize(body["connectUrl"])

          if session_id && endpoint do
            {:ok, %{id: session_id, cdp_endpoint: endpoint, features: features}}
          else
            {:error, "Browserbase create response omitted id or CDP endpoint"}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  @impl true
  def close_session(session_id, opts) do
    with {:ok, config} <- resolve_config(opts) do
      request = Keyword.get(opts, :http_post, &Req.post/2)

      case request.(config.base_url <> "/v1/sessions/" <> URI.encode(session_id),
             headers: headers(config.api_key),
             json: %{"projectId" => config.project_id, "status" => "REQUEST_RELEASE"},
             receive_timeout: 10_000
           ) do
        {:ok, %Req.Response{status: status}} when status in [200, 201, 204] -> :ok
        other -> Helpers.request_error("Browserbase", "close", other)
      end
    end
  end

  @impl true
  def status, do: %{provider: "browserbase", configured: available?(), transport: "cdp"}

  defp create_with_feature_fallback(request, config, body) do
    features = %{
      basic_stealth: true,
      proxies: Map.get(body, "proxies") == true,
      advanced_stealth: get_in(body, ["browserSettings", "advancedStealth"]) == true,
      keep_alive: Map.get(body, "keepAlive") == true,
      custom_timeout: Map.has_key?(body, "timeout")
    }

    case post_create(request, config, body) do
      {:ok, %Req.Response{status: 402}} when map_size(body) > 1 ->
        fallback_body = Map.drop(body, ["keepAlive", "proxies"])

        fallback_features =
          features
          |> Map.put(:keep_alive, false)
          |> Map.put(:proxies, false)

        case post_create(request, config, fallback_body) do
          {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
            {:ok, response, fallback_features}

          other ->
            Helpers.request_error("Browserbase", "create", other)
        end

      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response, features}

      other ->
        Helpers.request_error("Browserbase", "create", other)
    end
  end

  defp post_create(request, config, body) do
    request.(config.base_url <> "/v1/sessions",
      headers: headers(config.api_key),
      json: body,
      connect_options: [timeout: 30_000],
      receive_timeout: 30_000
    )
  end

  defp create_body(config) do
    %{"projectId" => config.project_id}
    |> maybe_put("keepAlive", config.keep_alive)
    |> maybe_put("proxies", config.proxies)
    |> maybe_put(
      "browserSettings",
      if(config.advanced_stealth, do: %{"advancedStealth" => true}, else: nil)
    )
    |> maybe_put("timeout", config.timeout_seconds)
  end

  defp resolve_config(opts) do
    api_key =
      Helpers.config(opts, :api_key) |> Helpers.normalize() ||
        Helpers.secret("BROWSERBASE_API_KEY")

    project_id =
      Helpers.config(opts, :project_id) |> Helpers.normalize() ||
        Helpers.secret("BROWSERBASE_PROJECT_ID")

    if api_key && project_id do
      timeout =
        Helpers.config(opts, :timeout_seconds, System.get_env("BROWSERBASE_SESSION_TIMEOUT"))
        |> case do
          nil -> nil
          value -> Helpers.positive_integer(value, 300, 21_600)
        end

      {:ok,
       %{
         api_key: api_key,
         project_id: project_id,
         base_url:
           Helpers.base_url(
             Helpers.config(opts, :base_url, System.get_env("BROWSERBASE_BASE_URL")),
             @default_base_url
           ),
         proxies:
           Helpers.truthy(
             Helpers.config(opts, :proxies, System.get_env("BROWSERBASE_PROXIES")),
             true
           ),
         advanced_stealth:
           Helpers.truthy(
             Helpers.config(
               opts,
               :advanced_stealth,
               System.get_env("BROWSERBASE_ADVANCED_STEALTH")
             ),
             false
           ),
         keep_alive:
           Helpers.truthy(
             Helpers.config(opts, :keep_alive, System.get_env("BROWSERBASE_KEEP_ALIVE")),
             true
           ),
         timeout_seconds: timeout
       }}
    else
      {:error, :missing_browserbase_credentials}
    end
  end

  defp headers(api_key) do
    [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"x-bb-api-key", api_key}
    ]
  end

  defp maybe_put(map, _key, value) when value in [nil, false], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
