defmodule LemonControlPlane.Methods.BackgroundCommandSupport do
  @moduledoc false

  alias LemonControlPlane.AgentRuntime

  def call(function, args), do: AgentRuntime.call(function, args, {:error, :unavailable})

  def opts(params) do
    []
    |> put(:parent_session, params["sessionId"])
    |> put(:session_key, params["sessionKey"] || params["sessionId"])
    |> put(:cwd, params["cwd"])
    |> put(:model, params["model"])
    |> put(:thinking_level, params["thinkingLevel"])
    |> put(:timeout_ms, params["timeoutMs"])
  end

  def stringify(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)
  end

  def stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  def stringify(value) when is_boolean(value) or is_nil(value), do: value
  def stringify(value) when is_atom(value), do: Atom.to_string(value)
  def stringify(value), do: value

  def error(:unavailable), do: {:error, {:internal_error, "Agent runtime unavailable", nil}}
  def error(:not_found), do: {:error, {:invalid_request, "Background run not found", nil}}
  def error(reason), do: {:error, {:internal_error, "Background command failed", reason}}

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
    case Support.call(:background_start, [prompt, Support.opts(params)]) do
      {:ok, result} -> {:ok, Support.stringify(result)}
      {:error, reason} -> Support.error(reason)
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
        {:ok, %{"runs" => Support.stringify(runs), "total" => length(runs)}}

      {:error, reason} ->
        Support.error(reason)
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
      {:ok, result} -> {:ok, Support.stringify(result)}
      {:error, reason} -> Support.error(reason)
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
      {:ok, answer} -> {:ok, %{"id" => id, "ready" => true, "answer" => answer}}
      {:error, :not_ready} -> {:ok, %{"id" => id, "ready" => false}}
      {:error, reason} -> Support.error(reason)
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
      {:error, reason} -> Support.error(reason)
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
        {:ok, answer} ->
          {:ok, %{"answer" => answer, "parentHistoryChanged" => false, "tools" => []}}

        {:error, reason} ->
          Support.error(reason)
      end
    else
      {:error, {:invalid_request, "sessionId or sessionKey and question are required", nil}}
    end
  end
end
