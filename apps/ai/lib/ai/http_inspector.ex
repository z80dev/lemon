defmodule Ai.HttpInspector do
  @moduledoc false

  require Logger

  @sensitive_headers ~w(authorization x-api-key cookie proxy-authorization)
  @redacted "[REDACTED]"
  @error_log_dir "~/.lemon/logs/http-errors"

  @type dump :: %{
          provider: String.t(),
          api: String.t(),
          model: String.t(),
          method: String.t(),
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: term(),
          timestamp: String.t()
        }

  @spec capture_request(String.t(), String.t(), String.t(), String.t(), String.t(), list(), term()) ::
          dump()
  def capture_request(provider, api, model, method, url, headers, body) do
    %{
      provider: provider,
      api: api,
      model: model,
      method: method,
      url: url,
      headers: headers,
      body: body,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @spec handle_error(String.t(), term(), dump()) :: String.t()
  def handle_error(message, error, dump) do
    status = get_status_code(error)

    if is_integer(status) and status >= 400 and status < 500 do
      save_error_dump(dump, status, error)

      sanitized = sanitize_dump(dump)

      "#{message} [HTTP #{status}] request_dump: #{inspect(sanitized, limit: :infinity, printable_limit: :infinity)}"
    else
      message
    end
  rescue
    e ->
      Logger.warning("HttpInspector.handle_error failed: #{Exception.message(e)}")
      message
  end

  @spec get_status_code(term()) :: integer() | nil
  def get_status_code(%{status: status}) when is_integer(status), do: status
  def get_status_code(%{status_code: status}) when is_integer(status), do: status
  def get_status_code(%{"status" => status}) when is_integer(status), do: status
  def get_status_code(%{"status_code" => status}) when is_integer(status), do: status
  def get_status_code({:error, %{status: status}}) when is_integer(status), do: status
  def get_status_code(status) when is_integer(status), do: status
  def get_status_code(_), do: nil

  @spec sanitize_dump(dump()) :: dump()
  def sanitize_dump(dump) do
    sanitized_headers =
      Enum.map(dump.headers, fn {key, value} ->
        if String.downcase(to_string(key)) in @sensitive_headers do
          {key, @redacted}
        else
          {key, value}
        end
      end)

    %{dump | headers: sanitized_headers}
  end

  defp save_error_dump(dump, status, error) do
    dir = Path.expand(@error_log_dir)

    with :ok <- File.mkdir_p(dir) do
      sanitized = sanitize_dump(dump)
      timestamp = String.replace(dump.timestamp, ~r/[:\.]/, "-")
      filename = "#{dump.provider}-#{status}-#{timestamp}.json"
      path = Path.join(dir, filename)

      json_safe_request = %{
        sanitized
        | headers: Map.new(sanitized.headers)
      }

      payload = %{
        request: json_safe_request,
        error_status: status,
        error_detail: inspect(error, limit: 200, printable_limit: 4_000)
      }

      case Jason.encode(payload, pretty: true) do
        {:ok, json} ->
          File.write(path, json)
          Logger.debug("HttpInspector: saved error dump to #{path}")

        {:error, reason} ->
          Logger.warning("HttpInspector: failed to encode dump: #{inspect(reason)}")
      end
    else
      {:error, reason} ->
        Logger.warning("HttpInspector: failed to create log dir: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("HttpInspector: save_error_dump failed: #{Exception.message(e)}")
  end
end
