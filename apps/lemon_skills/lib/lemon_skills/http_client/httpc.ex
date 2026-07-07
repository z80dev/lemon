defmodule LemonSkills.HttpClient.Httpc do
  @moduledoc "Default HTTP client using Erlang :httpc."
  @behaviour LemonSkills.HttpClient

  alias LemonCore.Httpc

  @impl true
  def fetch(url, headers) do
    headers_erl =
      Enum.map(headers, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    case Httpc.request(:get, {String.to_charlist(url), headers_erl}, [], []) do
      {:ok, {{_, status, _}, _resp_headers, body}} when status in 200..299 ->
        {:ok, to_string(body)}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
