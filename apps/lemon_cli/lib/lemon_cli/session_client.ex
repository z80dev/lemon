defmodule LemonCli.SessionClient do
  @moduledoc "Authenticated daemon-backed adapter for durable session management."
  alias LemonCli.ControlPlaneClient

  defmodule Error do
    defexception message: "The Lemon runtime could not complete the session operation.",
                 kind: "session_service_unavailable"
  end

  def ensure_running do
    case LemonCli.LocalRuntime.ensure_running() do
      :ok -> :ok
      {:error, _} -> raise Error, message: "The Lemon runtime could not be started."
    end
  end

  def list(opts) do
    payload = request!("sessions.list", options(opts))

    %{
      sessions: Enum.map(payload["sessions"], &normalize/1),
      matched: payload["total"],
      total: get_in(payload, ["summary", "storeTotal"]) || payload["total"]
    }
  end

  def stats(opts), do: {:ok, request!("sessions.stats", options(opts)) |> normalize()}

  def get(session_key) do
    case request("sessions.get", %{"sessionKey" => session_key}) do
      {:ok, payload} -> normalize(payload["session"])
      {:error, :not_found} -> nil
      {:error, _} -> raise Error
    end
  end

  def history(session_key, opts) do
    payload =
      request!("sessions.history", %{"sessionKey" => session_key, "limit" => opts[:limit] || 50})

    normalize(payload["history"])
  end

  @doc """
  The `sessions.context` breakdown, kept in its bounded wire shape (string
  keys) for printing and `--json` output.
  """
  def context(session_key, cwd) do
    request("sessions.context", %{"sessionKey" => session_key, "cwd" => cwd})
  end

  def patch(session_key, patch) do
    params =
      patch
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("sessionKey", session_key)

    case request("sessions.metadata.patch", params) do
      {:ok, _} ->
        case get(session_key) do
          nil -> {:error, :not_found}
          session -> {:ok, session}
        end

      error ->
        error
    end
  end

  def export(session_key, opts) do
    params = %{"sessionKey" => session_key, "format" => Atom.to_string(opts[:format] || :json)}

    case request("sessions.export", params) do
      {:ok, payload} ->
        summary = normalize(payload["summary"] || %{})
        export = normalize(Map.drop(payload, ["summary"]))
        format = export_format(payload["format"])
        {:ok, export |> Map.merge(summary) |> Map.put(:format, format)}

      error ->
        error
    end
  end

  defp export_format("jsonl"), do: :jsonl
  defp export_format("markdown"), do: :markdown
  defp export_format("html"), do: :html
  defp export_format(_other), do: :json

  def prune(opts) do
    case request("sessions.prune", %{
           "olderThanMs" => opts[:older_than_ms],
           "archivedOnly" => opts[:archived_only],
           "includePinned" => opts[:include_pinned],
           "dryRun" => opts[:dry_run],
           "confirmToken" => opts[:confirm_token]
         }) do
      {:ok, payload} ->
        result = payload |> Map.drop(["summary"]) |> normalize()

        {:ok,
         result
         |> Map.put(:confirmation_token, payload["confirmToken"])
         |> Map.delete(:confirm_token)}

      error ->
        error
    end
  end

  def delete(session_key) do
    case request("sessions.delete", %{"sessionKey" => session_key}) do
      {:ok, payload} ->
        {:ok, normalize(Map.merge(Map.drop(payload, ["summary"]), payload["summary"] || %{}))}

      error ->
        error
    end
  end

  defp options(opts) do
    keys = %{agent_id: "agentId", group_limit: "groupLimit"}

    Map.new(
      Enum.reject(opts, fn {_key, value} -> is_nil(value) or value == :all end),
      fn {key, value} -> {Map.get(keys, key, Atom.to_string(key)), value} end
    )
  end

  defp request!(method, params) do
    case request(method, params) do
      {:ok, result} -> result
      {:error, _} -> raise Error
    end
  end

  defp request(method, params) do
    case ControlPlaneClient.request(method, params) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, {:control_plane, %{"code" => "NOT_FOUND"}}} ->
        {:error, :not_found}

      {:error, {:control_plane, %{"code" => "UNAVAILABLE"}}} when method == "sessions.context" ->
        {:error, :unavailable}

      {:error, {:control_plane, %{"code" => "CONFLICT", "message" => message}}} ->
        if String.contains?(message, "candidates"),
          do: {:error, :confirmation_mismatch},
          else: {:error, :confirmation_required}

      {:error,
       {:control_plane,
        %{
          "code" => "INTERNAL_ERROR",
          "message" => "Some session deletions could not be verified",
          "details" => details
        }}}
      when method == "sessions.prune" and is_map(details) ->
        {:error, {:partial_failure, normalize(details)}}

      {:error, {:control_plane, %{"code" => code}}} when code in ["UNAUTHORIZED", "FORBIDDEN"] ->
        raise Error,
          kind: "session_authentication_failed",
          message:
            "Cannot authenticate to the running Lemon runtime; configure its operator token."

      {:error, _} ->
        raise Error
    end
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {normalize_key(key), normalize(item)} end)
  end

  defp normalize(value), do: value

  defp normalize_key(key) when is_binary(key) do
    key = Macro.underscore(key)

    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  defp normalize_key(key), do: key
end
