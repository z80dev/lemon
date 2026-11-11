defmodule LemonAi.Models.OpenAICodexDiscovery do
  @moduledoc """
  Account-scoped Codex model discovery, cached in the supervised `ModelCache`.

  Callers supply a concrete ChatGPT access token. Discovery never refreshes it,
  reads login files, or stores credentials. Cache keys contain an account digest
  and endpoint, not the token or account identifier. A successful empty list is
  authoritative; HTTP, transport and malformed responses are errors, never an
  excuse to advertise an unverified static Codex catalog.

  Only models whose coding protocol and pricing are present in the bundled
  registry are selectable. `visibility` is a presentation hint, not access
  control: a known model marked hidden can still be explicitly used by an account.
  An explicit `supported_in_api: false` excludes a model.
  """

  alias LemonAi.{ModelCache, Models}
  alias LemonAi.Types.Model

  @base_url "https://chatgpt.com/backend-api"
  @client_version "0.159.0"
  @ttl_ms 300_000
  @timeout_ms 5_000
  @claim_path "https://api.openai.com/auth"

  @type option ::
          {:access_token, String.t()}
          | {:base_url, String.t()}
          | {:timeout_ms, pos_integer()}
          | {:ttl_ms, non_neg_integer()}
          | {:force_refresh, boolean()}
          | {:req_options, keyword()}

  @spec discover([option()]) :: {:ok, [Model.t()]} | {:error, term()}
  def discover(opts \\ []) do
    token = Keyword.get(opts, :access_token)
    base_url = normalize_base_url(Keyword.get(opts, :base_url))

    with {:ok, account_id} <- account_id(token) do
      key = {:openai_codex, :crypto.hash(:sha256, account_id), :crypto.hash(:sha256, base_url)}

      case cached(key, opts) do
        {:ok, models} ->
          {:ok, models}

        :miss ->
          with {:ok, models} <- fetch_models(base_url, token, account_id, opts) do
            ModelCache.write(key, models, authoritative: true)
            {:ok, models}
          end
      end
    end
  rescue
    ArgumentError -> {:error, :discovery_cache_unavailable}
  end

  @doc "Return an actionable error before using a model unavailable to this account."
  @spec ensure_available(Model.t(), [option()]) :: :ok | {:error, String.t()}
  def ensure_available(%Model{provider: :openai_codex, id: id} = model, opts) do
    opts = Keyword.put_new(opts, :base_url, model.base_url)

    case discover(opts) do
      {:ok, models} ->
        if Enum.any?(models, &(&1.id == id)) do
          :ok
        else
          available = models |> Enum.map(& &1.id) |> Enum.sort() |> Enum.join(", ")
          available = if available == "", do: "none advertised for this account", else: available

          {:error,
           "Codex model #{id} is not available for this ChatGPT account. " <>
             "Choose an account-supported model in the model picker or update [model_roles] " <>
             "in config.toml. Available models: #{available}."}
        end

      {:error, reason} ->
        {:error,
         "Cannot verify Codex model #{id} for this ChatGPT account (#{format_reason(reason)}). " <>
           "Check the connection and configured ChatGPT login, then reopen the model picker."}
    end
  end

  def ensure_available(%Model{}, _opts), do: :ok

  @doc false
  def normalize_base_url(base_url)
      when base_url in [nil, "", "https://chatgpt.com", "https://chatgpt.com/"],
      do: @base_url

  def normalize_base_url(base_url) when is_binary(base_url) do
    base_url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.trim_trailing("/codex/responses")
    |> String.trim_trailing("/codex")
  end

  @doc false
  def account_id(token) when is_binary(token) and token != "" do
    with [_, encoded, _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(json),
         %{@claim_path => %{"chatgpt_account_id" => account_id}} <- claims,
         true <- is_binary(account_id) and account_id != "" do
      {:ok, account_id}
    else
      _ -> {:error, :invalid_chatgpt_access_token}
    end
  end

  def account_id(_), do: {:error, :missing_chatgpt_credentials}

  defp cached(key, opts) do
    if Keyword.get(opts, :force_refresh, false) do
      :miss
    else
      case ModelCache.read(key, Keyword.get(opts, :ttl_ms, @ttl_ms)) do
        {:ok, %{fresh: true, authoritative: true, models: models}} -> {:ok, models}
        _ -> :miss
      end
    end
  end

  defp fetch_models(base_url, token, account_id, opts) do
    headers = [
      {"authorization", "Bearer #{token}"},
      {"chatgpt-account-id", account_id},
      {"openai-beta", "responses=experimental"},
      {"originator", "pi"},
      {"version", @client_version},
      {"accept", "application/json"}
    ]

    request_options =
      Keyword.get(opts, :req_options, [])
      |> Keyword.merge(
        headers: headers,
        params: [client_version: @client_version],
        connect_options: [timeout: Keyword.get(opts, :timeout_ms, @timeout_ms)],
        receive_timeout: Keyword.get(opts, :timeout_ms, @timeout_ms),
        retry: false
      )

    Enum.reduce_while(["/codex/models", "/models"], {:error, :no_discovery_endpoint}, fn path,
                                                                                         _acc ->
      case Req.get(base_url <> path, request_options) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          case normalize_models(body) do
            {:ok, _} = result -> {:halt, result}
            {:error, _} = error -> {:cont, error}
          end

        {:ok, %Req.Response{status: status}} when status in [401, 403] ->
          {:halt, {:error, {:authentication_rejected, status}}}

        {:ok, %Req.Response{status: status}} ->
          {:cont, {:error, {:http_error, status}}}

        {:error, _reason} ->
          {:cont, {:error, :transport_failure}}
      end
    end)
  end

  defp normalize_models(body) when is_map(body) do
    case Map.get(body, "models") || Map.get(body, "data") do
      entries when is_list(entries) ->
        models =
          entries
          |> Enum.flat_map(fn
            entry when is_map(entry) ->
              id = entry["slug"] || entry["id"]

              if is_binary(id) and id != "" and entry["supported_in_api"] != false do
                case Models.get_model(:openai_codex, id) do
                  %Model{} = model ->
                    compat =
                      Map.merge(model.compat || %{}, %{
                        codex_visibility: entry["visibility"],
                        codex_tool_mode: entry["tool_mode"]
                      })

                    [%{model | compat: compat}]

                  _ ->
                    []
                end
              else
                []
              end

            _ ->
              []
          end)
          |> Enum.uniq_by(& &1.id)

        {:ok, models}

      _ ->
        {:error, :invalid_discovery_response}
    end
  end

  defp normalize_models(_), do: {:error, :invalid_discovery_response}

  defp format_reason({:authentication_rejected, status}), do: "login rejected, HTTP #{status}"
  defp format_reason({:http_error, status}), do: "discovery returned HTTP #{status}"
  defp format_reason(:missing_chatgpt_credentials), do: "no ChatGPT credentials configured"

  defp format_reason(:invalid_chatgpt_access_token),
    do: "configured credential is not a ChatGPT access token"

  defp format_reason(:transport_failure), do: "discovery connection failed"
  defp format_reason(_), do: "model discovery unavailable"
end
