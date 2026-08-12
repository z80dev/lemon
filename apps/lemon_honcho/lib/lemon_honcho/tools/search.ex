defmodule LemonHoncho.Tools.Search do
  @moduledoc """
  The `honcho_search` tool: semantic search over what Honcho has stored.

  This is the cheap counterpart to `LemonHoncho.Tools.Reasoning`. It returns
  the matching material verbatim and spends no inference on Honcho's side,
  which makes it the right tool for checking or quoting something that was
  actually said, and the wrong tool for a judgement that has to be synthesized
  from many sessions.

  ## Session scope, and the fallback that matters

  `scope: "session"` — the default — searches only the current conversation,
  which is what a model usually means by "what did we say about this". That
  requires knowing which Honcho session the run maps to. When the session
  manager has never seen this run, the id has to be *derived* rather than
  looked up, and a derived id may name a session that Honcho has no messages
  for; searching it would return nothing and read as "the user never mentioned
  it", which is a wrong answer rather than an empty one. So an unmapped session
  falls back to the workspace search and the result says which one ran.

  ## Distinct from `search_memory`

  Both search "memory", and they search different stores: `search_memory` reads
  the local memory files and session transcripts, and this reads Honcho's
  server-side record of past conversations and conclusions. The description
  says so, because a model that believes they are the same will use one and
  conclude the other is empty.

  ## The query is screened before it leaves

  A model-authored query is in practice often a verbatim paste of what the user
  just said, and it travels as a URL query parameter on a `GET`, which makes it
  a line in the far side's access log as well as a row in their store. So it
  goes through `LemonHoncho.Egress.screen/2`: clipped to 1,500 characters, then
  withheld entirely if it looks like it carries a credential.

  When it is withheld the call is *refused* rather than made without a query.
  `LemonHoncho.SessionManager` drops its retrieval query and reads on, because
  there the query is an optimisation; here the query is the request, and a
  search of nothing reported as a search of something would be a wrong answer.
  The refusal is an ordinary result — the turn continues and the model can
  rephrase — and neither it nor any log repeats the offending text.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonHoncho.{Config, Egress}
  alias LemonHoncho.Tools.Common

  # The model-facing name, used both in the definition and in the debug line a
  # failed call writes, so a log entry always names a tool the model can see.
  @tool_name "honcho_search"

  @scopes ~w(session workspace)
  @default_limit 10
  @max_limit 100
  @excerpt_max_chars 1_000

  # The same cut `LemonHoncho.SessionManager` applies to the retrieval query it
  # sends to these very endpoints. A search query is a phrase describing an idea,
  # not a document, and the two paths hitting one endpoint under two different
  # budgets would be arbitrary.
  @max_query_chars 1_500

  @description """
  Semantic search over what Honcho has stored about this user — past messages and the conclusions drawn from \
  them — returning the matching excerpts verbatim, with no synthesis. Use it to find what was actually said, and \
  prefer it over honcho_reasoning whenever a quote or one specific detail would answer the question, since it \
  costs no server-side reasoning. Searches the current conversation by default; pass scope="workspace" to search \
  every session Honcho holds for this user. This searches Honcho's own store and is separate from search_memory, \
  which searches the local memory files — an empty result here says nothing about what is in those.\
  """

  @doc """
  The `honcho_search` tool definition.

  `opts` is the session's tool option list; its session key, session id, and
  cwd decide which conversation a `scope: "session"` search covers.
  """
  @spec tool(keyword()) :: AgentTool.t()
  def tool(opts \\ []) do
    %AgentTool{
      name: @tool_name,
      description: @description,
      label: "Honcho Search",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" =>
              "What to look for. Matched semantically, so a phrase describing the idea works better than keywords."
          },
          "limit" => %{
            "type" => "integer",
            "description" =>
              "Maximum number of excerpts to return (default: #{@default_limit}, max: #{@max_limit})."
          },
          "scope" => %{
            "type" => "string",
            "enum" => @scopes,
            "description" =>
              ~s|"session" (the default) searches this conversation only; "workspace" searches every | <>
                "session stored for this user."
          }
        },
        "required" => ["query"]
      },
      execute: &execute(&1, &2, &3, &4, opts)
    }
  end

  @doc "The tool definition for a run rooted at `cwd`."
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts), do: tool(Keyword.put(opts, :cwd, cwd))

  @doc "Runs `honcho_search` with no session options; see `execute/5`."
  @spec execute(String.t(), map(), reference() | nil, function() | nil) :: AgentToolResult.t()
  def execute(tool_call_id, params, signal, on_update) do
    execute(tool_call_id, params, signal, on_update, [])
  end

  @doc """
  Runs `honcho_search`, scoped to the session named in `opts`.

  Always returns an `t:LemonAgent.Types.AgentToolResult.t/0`; nothing here ends
  a turn with an error.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, keyword()) ::
          AgentToolResult.t()
  def execute(_tool_call_id, params, _signal, _on_update, opts) do
    config = Config.load()

    with :ok <- Common.gate(config),
         {:ok, request} <- normalize(params),
         scope = Common.scope(config, opts),
         searched = searched_scope(request, scope),
         {:ok, hits} <- search(config, request, scope, searched) do
      format(hits, request, scope, searched)
    else
      {:error, :not_configured} -> not_configured()
      {:error, :context_only} -> context_only()
      {:error, {:invalid_input, message}} -> failure(message)
      {:error, {:withheld, parameter}} -> withheld(parameter)
      {:error, {:unauthorized, _body}} -> failure(Common.unauthorized_message())
      {:error, {:api_error, status, body}} -> failure(Common.api_message(status, body))
      {:error, reason} -> failure("Honcho search failed: #{inspect(reason)}")
    end
  end

  ## Parameters

  defp normalize(params) do
    with {:ok, query} <- query(Map.get(params, "query")),
         {:ok, limit} <- limit(Map.get(params, "limit")),
         {:ok, scope} <- scope_param(Map.get(params, "scope")) do
      {:ok, %{query: query, limit: limit, scope: scope}}
    end
  end

  defp query(nil), do: {:error, {:invalid_input, "Missing required parameter: query"}}

  defp query(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_input, "Parameter 'query' cannot be empty"}}
      trimmed -> screen(trimmed)
    end
  end

  defp query(_value), do: {:error, {:invalid_input, "Parameter 'query' must be a string"}}

  # The clip and the credential screen happen here rather than at the call, so
  # what `details.query` echoes and what the result text quotes is exactly the
  # string that went on the wire.
  defp screen(trimmed) do
    case Egress.screen(trimmed, @max_query_chars) do
      nil -> {:error, {:withheld, "query"}}
      screened -> {:ok, screened}
    end
  end

  defp limit(nil), do: {:ok, @default_limit}
  defp limit(value) when is_integer(value) and value > 0, do: {:ok, min(value, @max_limit)}

  defp limit(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {parsed, ""} -> limit(parsed)
      _other -> {:error, {:invalid_input, limit_message()}}
    end
  end

  defp limit(_value), do: {:error, {:invalid_input, limit_message()}}

  defp limit_message, do: "Parameter 'limit' must be a positive integer"

  defp scope_param(nil), do: {:ok, "session"}

  defp scope_param(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> {:ok, "session"}
      scope when scope in @scopes -> {:ok, scope}
      _other -> {:error, {:invalid_input, scope_message()}}
    end
  end

  defp scope_param(_value), do: {:error, {:invalid_input, scope_message()}}

  defp scope_message, do: "Parameter 'scope' must be one of: #{Enum.join(@scopes, ", ")}"

  ## The call

  # A session search is only meaningful against a session Honcho actually knows
  # about; see the moduledoc for why an unmapped one widens rather than returns
  # an empty list.
  defp searched_scope(%{scope: "session"}, %{mapped?: true}), do: :session
  defp searched_scope(_request, _scope), do: :workspace

  defp search(%Config{} = config, request, scope, :session) do
    Common.client().session_search(config, scope.session_id, request.query, limit: request.limit)
  end

  defp search(%Config{} = config, request, _scope, :workspace) do
    Common.client().workspace_search(config, request.query, limit: request.limit)
  end

  ## Results

  defp format([], request, scope, searched) do
    text =
      "No stored Honcho material matches #{inspect(request.query)} (#{searched_label(searched)})."

    result(text, request, scope, searched, [])
  end

  defp format(hits, request, scope, searched) do
    excerpts = Enum.map(hits, &excerpt/1)

    text = """
    #{length(excerpts)} Honcho excerpt(s) matching #{inspect(request.query)} (#{searched_label(searched)}):

    #{Enum.join(excerpts, "\n---\n")}
    """

    result(text, request, scope, searched, excerpts)
  end

  defp searched_label(:session), do: "this session"
  defp searched_label(:workspace), do: "all sessions"

  # Honcho's search results are messages, and the field a message's text lives
  # under has varied between API versions; anything unrecognized is inspected
  # rather than dropped, because a result the model cannot see is worse than an
  # ugly one it can.
  defp excerpt(hit) when is_map(hit) do
    text = hit |> first_string(["content", "text", "message"]) |> clip()
    label = first_string(hit, ["peer_id", "peer", "author"])
    stamp = first_string(hit, ["created_at", "createdAt", "timestamp"])

    case Enum.reject([label, stamp], &is_nil/1) do
      [] -> text || inspect(hit)
      parts -> Enum.join(parts, " · ") <> "\n" <> (text || inspect(hit))
    end
  end

  defp excerpt(hit), do: inspect(hit)

  defp first_string(hit, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(hit, key) do
        value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
        _other -> nil
      end
    end)
  end

  defp clip(nil), do: nil
  defp clip(text), do: String.slice(text, 0, @excerpt_max_chars)

  defp result(text, request, scope, searched, excerpts) do
    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        query: request.query,
        limit: request.limit,
        requested_scope: request.scope,
        searched_scope: searched,
        session_id: scope.session_id,
        count: length(excerpts),
        excerpts: excerpts
      }
    }
  end

  defp not_configured do
    Common.not_configured("there is nothing stored to search")
  end

  defp context_only do
    Common.context_only(
      ". What Honcho knows about this user is already in your system prompt — read it there.",
      "query it directly"
    )
  end

  # A refusal, not an error: the model can only rephrase if the turn survives.
  # The parameter is named and the value is not — repeating it here would put it
  # in the transcript, which is the one place it has not reached yet.
  defp withheld(parameter) do
    text = """
    The '#{parameter}' you passed looks like it carries a credential — a password, \
    API key, token, or private key — so it was not sent to Honcho and no search ran. \
    Nothing was stored and nothing was logged. Rephrase it without the credential \
    material and call this tool again.
    """

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{error: :withheld, parameter: parameter}
    }
  end

  defp failure(message), do: Common.failure(@tool_name, message)
end
