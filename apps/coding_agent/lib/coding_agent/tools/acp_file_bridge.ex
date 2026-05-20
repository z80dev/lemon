defmodule CodingAgent.Tools.ACPFileBridge do
  @moduledoc false

  @timeout_ms 60_000

  def read_enabled?(opts), do: Keyword.get(opts, :acp_client_fs_read_text_file) == true
  def write_enabled?(opts), do: Keyword.get(opts, :acp_client_fs_write_text_file) == true
  def delete_enabled?(opts), do: Keyword.get(opts, :acp_client_fs_delete_file) == true
  def rename_enabled?(opts), do: Keyword.get(opts, :acp_client_fs_rename_file) == true

  def read_text_file(path, offset, limit, opts) when is_binary(path) do
    params =
      %{"path" => path}
      |> maybe_put("line", normalize_line(offset))
      |> maybe_put("limit", normalize_limit(limit))

    with {:ok, response} <- request("fs/read_text_file", params, opts),
         {:ok, result} <- response_result(response),
         content when is_binary(content) <-
           Map.get(result, "content") || Map.get(result, :content) do
      {:ok, content}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "ACP client read response did not include text content"}
    end
  end

  def write_text_file(path, content, opts) when is_binary(path) and is_binary(content) do
    with {:ok, response} <-
           request("fs/write_text_file", %{"path" => path, "content" => content}, opts),
         {:ok, _result} <- response_result(response) do
      :ok
    end
  end

  def delete_file(path, opts) when is_binary(path) do
    with {:ok, response} <- request("fs/delete_file", %{"path" => path}, opts),
         {:ok, _result} <- response_result(response) do
      :ok
    end
  end

  def rename_file(source_path, target_path, opts)
      when is_binary(source_path) and is_binary(target_path) do
    with {:ok, response} <-
           request("fs/rename_file", %{"path" => source_path, "targetPath" => target_path}, opts),
         {:ok, _result} <- response_result(response) do
      :ok
    end
  end

  def request(method, params, opts) do
    run_id = Keyword.get(opts, :run_id)

    if is_binary(run_id) and run_id != "" do
      ref = make_ref()

      LemonCore.Bus.broadcast(
        LemonCore.Bus.run_topic(run_id),
        LemonCore.Event.new(
          :acp_client_request,
          %{method: method, params: params, reply_to: self(), ref: ref},
          %{run_id: run_id, session_key: Keyword.get(opts, :session_key)}
        )
      )

      receive do
        {:acp_client_response, ^ref, response} -> {:ok, response}
      after
        Keyword.get(opts, :acp_client_timeout_ms, @timeout_ms) ->
          {:error, "ACP client request timed out"}
      end
    else
      {:error, "ACP client request requires run_id"}
    end
  end

  defp response_result(%{"error" => %{"message" => message}}), do: {:error, message}
  defp response_result(%{"error" => error}), do: {:error, inspect(error)}
  defp response_result(%{error: %{message: message}}), do: {:error, message}
  defp response_result(%{error: error}), do: {:error, inspect(error)}

  defp response_result(%{"result" => result}) when is_map(result) or is_nil(result),
    do: {:ok, result || %{}}

  defp response_result(%{result: result}) when is_map(result) or is_nil(result),
    do: {:ok, result || %{}}

  defp response_result(result) when is_map(result), do: {:ok, result}
  defp response_result(_), do: {:ok, %{}}

  defp normalize_line(value) when is_integer(value) and value > 0, do: value
  defp normalize_line(_), do: 1

  defp normalize_limit(value) when is_integer(value) and value > 0, do: value
  defp normalize_limit(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
