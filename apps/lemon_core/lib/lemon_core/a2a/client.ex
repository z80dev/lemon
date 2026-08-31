defmodule LemonCore.A2A.Client do
  @moduledoc """
  Minimal A2A v1.0 JSON-RPC client built on OTP `:httpc`.

  Callers supply already-resolved credentials. This module never reads config
  or secret stores and never includes bearer values in returned errors.
  """

  alias LemonCore.A2A.Protocol
  alias LemonCore.Httpc

  @spec agent_card(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def agent_card(base_url, opts \\ []) do
    get_json(join(base_url, "/.well-known/agent-card.json"), opts)
  end

  @spec send_message(binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_message(base_url, message, opts \\ []) do
    call(base_url, "SendMessage", %{"message" => message}, opts)
  end

  @spec get_task(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_task(base_url, task_id, opts \\ []) do
    call(base_url, "GetTask", %{"id" => task_id}, opts)
  end

  @spec list_tasks(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_tasks(base_url, opts \\ []), do: call(base_url, "ListTasks", %{}, opts)

  @spec cancel_task(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel_task(base_url, task_id, opts \\ []) do
    call(base_url, "CancelTask", %{"id" => task_id}, opts)
  end

  @spec call(binary(), binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(base_url, method, params, opts \\ []) do
    body = Protocol.request(method, params) |> Jason.encode!()
    headers = request_headers(opts)
    timeout = Keyword.get(opts, :timeout, 300_000)

    request =
      {String.to_charlist(String.trim_trailing(base_url, "/")), headers, ~c"application/json",
       body}

    case Httpc.request(:post, request, [timeout: timeout], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, response}} when status in 200..299 -> decode(response)
      {:ok, {{_, status, _}, _headers, _response}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, sanitize(reason)}
    end
  end

  defp get_json(url, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    case Httpc.request(
           :get,
           {String.to_charlist(url), request_headers(opts)},
           [timeout: timeout],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _headers, response}} when status in 200..299 -> decode(response)
      {:ok, {{_, status, _}, _headers, _response}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, sanitize(reason)}
    end
  end

  defp request_headers(opts) do
    [{~c"accept", ~c"application/json"}]
    |> maybe_auth(Keyword.get(opts, :token))
  end

  defp maybe_auth(headers, token) when is_binary(token) and token != "" do
    [{~c"authorization", String.to_charlist("Bearer " <> token)} | headers]
  end

  defp maybe_auth(headers, _), do: headers

  defp decode(body) do
    case Jason.decode(to_string(body)) do
      {:ok, %{"error" => error}} -> {:error, {:remote_error, error}}
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp join(base, path), do: String.trim_trailing(base, "/") <> path

  # `:httpc` errors may contain the full request tuple. Never return it to a
  # caller because that tuple can contain the Authorization header.
  defp sanitize({:failed_connect, details}) when is_list(details), do: {:failed_connect, :peer}
  defp sanitize({:timeout, _}), do: :timeout
  defp sanitize(reason) when is_atom(reason), do: reason
  defp sanitize(_), do: :request_failed
end
