defmodule LemonMedia.Providers.Http do
  @moduledoc """
  The one retry/error helper shared by every media provider driver.

  A request is a 0-arity function returning `{:ok, %{status: _, body: _}}` or
  `{:error, reason}` (the shape of `Req.post/2` and `Req.get/2`). Transient
  statuses (408, 409, 425, 429, 5xx) and transport errors are retried at most
  `retries` times; everything else fails with a redacted error kind built from
  `tag`: `{:"<tag>_http_error", status, {:safe_error_kind, label}}` or
  `{:"<tag>_request_failed", {:safe_error_kind, label}}`. Raw provider bodies
  never reach the error.
  """

  @spec request((-> {:ok, map()} | {:error, term()}), non_neg_integer(), atom()) ::
          {:ok, term()} | {:error, term()}
  def request(fun, retries, tag) do
    case fun.() do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        if transient_status?(status) and retries > 0 do
          request(fun, retries - 1, tag)
        else
          {:error, {:"#{tag}_http_error", status, provider_error_kind(body)}}
        end

      {:error, _reason} when retries > 0 ->
        request(fun, retries - 1, tag)

      {:error, reason} ->
        {:error, {:"#{tag}_request_failed", provider_error_kind(reason)}}
    end
  end

  @spec transient_status?(term()) :: boolean()
  def transient_status?(status) when status in [408, 409, 425, 429], do: true
  def transient_status?(status) when is_integer(status) and status >= 500, do: true
  def transient_status?(_status), do: false

  @doc "Reduces a provider error body or transport reason to a safe label."
  @spec provider_error_kind(term()) :: {:safe_error_kind, String.t()}
  def provider_error_kind(%{"error" => error}) when is_map(error) do
    {:safe_error_kind,
     optional_string(error["type"]) || optional_string(error["status"]) ||
       optional_string(error["code"]) || "provider_error"}
  end

  def provider_error_kind(%{error: error}) when is_map(error) do
    provider_error_kind(%{
      "error" => %{"type" => error[:type], "status" => error[:status], "code" => error[:code]}
    })
  end

  def provider_error_kind(%{"detail" => detail}) when is_map(detail) do
    {:safe_error_kind,
     optional_string(detail["status"]) || optional_string(detail["type"]) ||
       optional_string(detail["code"]) || "provider_error"}
  end

  def provider_error_kind(%{detail: detail}) when is_map(detail) do
    provider_error_kind(%{
      "detail" => %{"status" => detail[:status], "type" => detail[:type], "code" => detail[:code]}
    })
  end

  def provider_error_kind(reason) when is_atom(reason),
    do: {:safe_error_kind, Atom.to_string(reason)}

  def provider_error_kind(_reason), do: {:safe_error_kind, "provider_error"}

  @doc false
  def optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def optional_string(_value), do: nil

  @doc false
  def reject_blank_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
  end

  @doc false
  def url(base_url, path), do: String.trim_trailing(base_url, "/") <> path

  @doc false
  def post_fun(runtime), do: Map.get(runtime, :http_post) || (&Req.post/2)

  @doc false
  def get_fun(runtime), do: Map.get(runtime, :http_get) || (&Req.get/2)

  @doc false
  def api_key(%{credential: credential}) when is_function(credential, 0), do: credential.()
end
