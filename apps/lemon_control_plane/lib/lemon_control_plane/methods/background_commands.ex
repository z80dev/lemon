defmodule LemonControlPlane.Methods.BackgroundCommandSupport do
  @moduledoc false

  alias LemonControlPlane.AgentRuntime
  alias LemonRouter.ThinkingLevel

  @statuses ~w(queued running completed error lost killed cancelled tracking_lost)
  @max_id_bytes 256

  def call(function, args), do: AgentRuntime.call(function, args, {:error, :unavailable})

  def opts(params) do
    []
    |> put(:parent_session, params["sessionId"])
    |> put(:session_key, params["sessionKey"] || params["sessionId"])
    |> put(:cwd, params["cwd"])
    |> put(:model, params["model"])
    |> put(:thinking_level, ThinkingLevel.normalize(params["thinkingLevel"]))
    |> put(:timeout_ms, params["timeoutMs"])
  end

  def validate_thinking_level(%{"thinkingLevel" => level}) when is_binary(level) do
    if ThinkingLevel.valid_string?(level) do
      :ok
    else
      {:error,
       {:invalid_params,
        "thinkingLevel must be one of: #{Enum.join(ThinkingLevel.allowed_strings(), ", ")}",
        %{"field" => "thinkingLevel"}}}
    end
  end

  def validate_thinking_level(_params), do: :ok

  def project_start(result) when is_map(result) do
    with {:ok, id} <- identifier(fetch(result, :id)),
         {:ok, status} <- status(fetch(result, :status)) do
      {:ok, %{"id" => id, "status" => status}}
    else
      _ -> {:error, :invalid_runtime_response}
    end
  end

  def project_start(_result), do: {:error, :invalid_runtime_response}

  def project_runs(runs) when is_list(runs) do
    Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, projected} ->
      case project_summary(run) do
        {:ok, summary} -> {:cont, {:ok, [summary | projected]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      error -> error
    end
  end

  def project_runs(_runs), do: {:error, :invalid_runtime_response}

  def project_summary(summary) when is_map(summary) do
    with {:ok, id} <- identifier(fetch(summary, :id)),
         {:ok, status} <- status(fetch(summary, :status)) do
      payload =
        %{
          "id" => id,
          "status" => status,
          "result_available" => boolean(fetch(summary, :result_available), status == "completed")
        }
        |> put_optional_identifier("session_id", fetch(summary, :session_id))
        |> put_optional_identifier("parent_session_key", fetch(summary, :parent_session_key))
        |> put_optional_integer("inserted_at", fetch(summary, :inserted_at))
        |> put_optional_integer("updated_at", fetch(summary, :updated_at))
        |> put_optional_integer("started_at", fetch(summary, :started_at))
        |> put_optional_integer("completed_at", fetch(summary, :completed_at))
        |> put_failure_code(status)

      {:ok, payload}
    else
      _ -> {:error, :invalid_runtime_response}
    end
  end

  def project_summary(_summary), do: {:error, :invalid_runtime_response}

  def error(operation, reason) do
    {rpc_code, message, public_code} = public_error(operation, reason)
    {:error, {rpc_code, message, %{"code" => public_code}}}
  end

  defp public_error(_operation, :unavailable),
    do: {:unavailable, "Agent runtime unavailable", "AGENT_RUNTIME_UNAVAILABLE"}

  defp public_error(_operation, :not_found),
    do: {:not_found, "Background run not found", "BACKGROUND_NOT_FOUND"}

  defp public_error(_operation, :not_ready),
    do: {:conflict, "Background run is not ready", "BACKGROUND_NOT_READY"}

  defp public_error(_operation, :lost),
    do: {:unavailable, "Background run is no longer available", "BACKGROUND_LOST"}

  defp public_error(_operation, :already_terminal),
    do: {:conflict, "Background run is already terminal", "BACKGROUND_ALREADY_TERMINAL"}

  defp public_error(:btw, :session_not_found),
    do: {:not_found, "Session context not found", "SESSION_CONTEXT_NOT_FOUND"}

  defp public_error(:btw, reason) when reason in [:session_unavailable, :history_unavailable],
    do: {:unavailable, "Session context unavailable", "SESSION_CONTEXT_UNAVAILABLE"}

  defp public_error(:btw, :timeout),
    do: {:timeout, "Side query timed out", "SIDE_QUERY_TIMEOUT"}

  defp public_error(:btw, :cancelled),
    do: {:conflict, "Side query was cancelled", "SIDE_QUERY_CANCELLED"}

  defp public_error(_operation, :cancelled),
    do: {:conflict, "Background run was cancelled", "BACKGROUND_CANCELLED"}

  defp public_error(:start, _reason),
    do: {:internal_error, "Unable to start background run", "BACKGROUND_START_FAILED"}

  defp public_error(:list, _reason),
    do: {:internal_error, "Unable to list background runs", "BACKGROUND_LIST_FAILED"}

  defp public_error(:status, _reason),
    do: {:internal_error, "Unable to read background run status", "BACKGROUND_STATUS_FAILED"}

  defp public_error(:result, _reason),
    do: {:internal_error, "Unable to read background run result", "BACKGROUND_RESULT_FAILED"}

  defp public_error(:cancel, _reason),
    do: {:internal_error, "Unable to cancel background run", "BACKGROUND_CANCEL_FAILED"}

  defp public_error(:btw, _reason),
    do: {:internal_error, "Unable to answer side query", "SIDE_QUERY_FAILED"}

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp identifier(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= @max_id_bytes,
      do: {:ok, value},
      else: {:error, :invalid_identifier}
  end

  defp identifier(_value), do: {:error, :invalid_identifier}

  defp status(value) when is_atom(value), do: status(Atom.to_string(value))
  defp status(value) when value in @statuses, do: {:ok, value}
  defp status(_value), do: {:error, :invalid_status}

  defp boolean(value, _default) when is_boolean(value), do: value
  defp boolean(_value, default), do: default

  defp put_optional_identifier(payload, _key, nil), do: payload

  defp put_optional_identifier(payload, key, value) do
    case identifier(value) do
      {:ok, value} -> Map.put(payload, key, value)
      {:error, _reason} -> payload
    end
  end

  defp put_optional_integer(payload, _key, nil), do: payload

  defp put_optional_integer(payload, key, value) when is_integer(value),
    do: Map.put(payload, key, value)

  defp put_optional_integer(payload, _key, _value), do: payload

  defp put_failure_code(payload, "error"), do: Map.put(payload, "errorCode", "BACKGROUND_FAILED")
  defp put_failure_code(payload, "lost"), do: Map.put(payload, "errorCode", "BACKGROUND_LOST")
  defp put_failure_code(payload, "killed"), do: Map.put(payload, "errorCode", "BACKGROUND_KILLED")

  defp put_failure_code(payload, "cancelled"),
    do: Map.put(payload, "errorCode", "BACKGROUND_CANCELLED")

  defp put_failure_code(payload, _status), do: payload

  defp put(opts, _key, nil), do: opts
  defp put(opts, _key, ""), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)
end

defmodule LemonControlPlane.Methods.BackgroundStart do
  @moduledoc "Starts an isolated full-tool background Lemon session."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.BackgroundCommandSupport, as: Support

  @impl true
  def name, do: "background.start"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(%{"prompt" => prompt} = params, _ctx) when is_binary(prompt) do
    with :ok <- Support.validate_thinking_level(params) do
      case Support.call(:background_start, [prompt, Support.opts(params)]) do
        {:ok, result} ->
          case Support.project_start(result) do
            {:ok, payload} -> {:ok, payload}
            {:error, reason} -> Support.error(:start, reason)
          end

        {:error, reason} ->
          Support.error(:start, reason)

        _other ->
          Support.error(:start, :invalid_runtime_response)
      end
    end
  end

  def handle(_, _), do: {:error, {:invalid_request, "prompt is required", nil}}
end

defmodule LemonControlPlane.Methods.BackgroundList do
  @moduledoc "Lists durable background command runs."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.BackgroundCommandSupport, as: Support

  @impl true
  def name, do: "background.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    opts = if is_binary(params["status"]), do: [status: params["status"]], else: []

    case Support.call(:background_list, [opts]) do
      runs when is_list(runs) ->
        case Support.project_runs(runs) do
          {:ok, projected} -> {:ok, %{"runs" => projected, "total" => length(projected)}}
          {:error, reason} -> Support.error(:list, reason)
        end

      {:error, reason} ->
        Support.error(:list, reason)

      _other ->
        Support.error(:list, :invalid_runtime_response)
    end
  end
end

defmodule LemonControlPlane.Methods.BackgroundStatus do
  @moduledoc "Returns one background command lifecycle summary."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.BackgroundCommandSupport, as: Support

  @impl true
  def name, do: "background.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(%{"id" => id}, _ctx) when is_binary(id) do
    case Support.call(:background_status, [id]) do
      {:ok, result} ->
        case Support.project_summary(result) do
          {:ok, payload} -> {:ok, payload}
          {:error, reason} -> Support.error(:status, reason)
        end

      {:error, reason} ->
        Support.error(:status, reason)

      _other ->
        Support.error(:status, :invalid_runtime_response)
    end
  end

  def handle(_, _), do: {:error, {:invalid_request, "id is required", nil}}
end

defmodule LemonControlPlane.Methods.BackgroundResult do
  @moduledoc "Returns a completed background command answer when ready."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.BackgroundCommandSupport, as: Support

  @impl true
  def name, do: "background.result"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(%{"id" => id}, _ctx) when is_binary(id) do
    case Support.call(:background_result, [id]) do
      {:ok, answer} when is_binary(answer) ->
        {:ok, %{"id" => id, "ready" => true, "answer" => answer}}

      {:ok, _invalid_answer} ->
        Support.error(:result, :invalid_runtime_response)

      {:error, :not_ready} ->
        {:ok, %{"id" => id, "ready" => false}}

      {:error, reason} ->
        Support.error(:result, reason)

      _other ->
        Support.error(:result, :invalid_runtime_response)
    end
  end

  def handle(_, _), do: {:error, {:invalid_request, "id is required", nil}}
end

defmodule LemonControlPlane.Methods.BackgroundCancel do
  @moduledoc "Cancels a queued or running background command."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.BackgroundCommandSupport, as: Support

  @impl true
  def name, do: "background.cancel"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(%{"id" => id}, _ctx) when is_binary(id) do
    case Support.call(:background_cancel, [id]) do
      :ok -> {:ok, %{"id" => id, "cancelled" => true}}
      {:error, reason} -> Support.error(:cancel, reason)
      _other -> Support.error(:cancel, :invalid_runtime_response)
    end
  end

  def handle(_, _), do: {:error, {:invalid_request, "id is required", nil}}
end

defmodule LemonControlPlane.Methods.SessionBtw do
  @moduledoc "Runs a bounded no-tools side question from a session snapshot."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.BackgroundCommandSupport, as: Support

  @impl true
  def name, do: "session.btw"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    source = params["sessionId"] || params["sessionKey"]
    question = params["question"]

    if is_binary(source) and source != "" and is_binary(question) and String.trim(question) != "" do
      opts = Support.opts(params)

      case Support.call(:side_query, [source, question, opts]) do
        {:ok, answer} when is_binary(answer) ->
          {:ok, %{"answer" => answer, "parentHistoryChanged" => false, "tools" => []}}

        {:ok, _invalid_answer} ->
          Support.error(:btw, :invalid_runtime_response)

        {:error, reason} ->
          Support.error(:btw, reason)

        _other ->
          Support.error(:btw, :invalid_runtime_response)
      end
    else
      {:error, {:invalid_request, "sessionId or sessionKey and question are required", nil}}
    end
  end
end
