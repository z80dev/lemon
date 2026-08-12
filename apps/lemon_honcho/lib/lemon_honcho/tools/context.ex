defmodule LemonHoncho.Tools.Context do
  @moduledoc """
  The `honcho_context` tool: everything Honcho currently holds for this session.

  Where `LemonHoncho.Tools.Reasoning` answers a question and
  `LemonHoncho.Tools.Search` finds an excerpt, this returns the whole picture —
  the rolling session summary, Honcho's representation of the user, the user's
  profile card, and the most recent messages it has stored. It is what a model
  reaches for when it wants to know what the memory layer actually contains
  rather than what it says about one topic, and it is what an operator reaches
  for when the injected context looks stale or wrong.

  Two plain reads and no server-side inference, so it is cheap. The `tokens`
  parameter is forwarded to Honcho as its own budget rather than trimmed here,
  which means the service decides what to drop and the result is never cut
  mid-sentence by us.

  ## This is the same material the system prompt was built from

  In `:hybrid` mode the session manager has already injected a rendered version
  of most of this. The tool exists anyway because the injected block is subject
  to cadences and budgets: it may be a turn or two old, and it may have been
  truncated. Calling this is how the model gets the current, unabridged version
  — including the recent messages, which the injected block never carries.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonHoncho.Config
  alias LemonHoncho.Tools.Common

  # The model-facing name, used both in the definition and in the debug line a
  # failed call writes, so a log entry always names a tool the model can see.
  @tool_name "honcho_context"

  @message_max_chars 500
  @max_messages 20

  @description """
  Return everything Honcho currently holds for this conversation: its rolling summary, its representation of the \
  user, the user's profile card, and the most recent messages it has stored. Reach for it when you want the whole \
  picture rather than the answer to one question — checking what the memory layer actually knows, or confirming \
  whether the background in your system prompt is current, since that copy is refreshed on a cadence and may lag. \
  Costs two plain reads and no server-side reasoning.\
  """

  @doc """
  The `honcho_context` tool definition.

  `opts` is the session's tool option list; its session key, session id, and
  cwd decide which session's context is read.
  """
  @spec tool(keyword()) :: AgentTool.t()
  def tool(opts \\ []) do
    %AgentTool{
      name: @tool_name,
      description: @description,
      label: "Honcho Context",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "tokens" => %{
            "type" => "integer",
            "description" =>
              "Optional token budget for the assembled context. Honcho trims to fit; omit for its own default."
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, opts)
    }
  end

  @doc "The tool definition for a run rooted at `cwd`."
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts), do: tool(Keyword.put(opts, :cwd, cwd))

  @doc "Runs `honcho_context` with no session options; see `execute/5`."
  @spec execute(String.t(), map(), reference() | nil, function() | nil) :: AgentToolResult.t()
  def execute(tool_call_id, params, signal, on_update) do
    execute(tool_call_id, params, signal, on_update, [])
  end

  @doc """
  Runs `honcho_context`, scoped to the session named in `opts`.

  Always returns an `t:LemonAgent.Types.AgentToolResult.t/0`. The two reads are
  independent: when one fails and the other succeeds the result is what could
  be read, and only a pair of failures is reported as an error.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, keyword()) ::
          AgentToolResult.t()
  def execute(_tool_call_id, params, _signal, _on_update, opts) do
    config = Config.load()

    with :ok <- Common.gate(config),
         {:ok, request} <- normalize(params),
         scope = Common.scope(config, opts),
         {:ok, parts} <- fetch(config, request, scope) do
      format(parts, scope)
    else
      {:error, :not_configured} -> not_configured()
      {:error, :context_only} -> context_only()
      {:error, {:invalid_input, message}} -> failure(message)
      {:error, {:unauthorized, _body}} -> failure(Common.unauthorized_message())
      {:error, {:api_error, status, body}} -> failure(Common.api_message(status, body))
      {:error, reason} -> failure("Honcho context read failed: #{inspect(reason)}")
    end
  end

  ## Parameters

  defp normalize(params) do
    case tokens(Map.get(params, "tokens")) do
      {:ok, tokens} -> {:ok, %{tokens: tokens}}
      error -> error
    end
  end

  defp tokens(nil), do: {:ok, nil}
  defp tokens(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp tokens(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {parsed, ""} -> tokens(parsed)
      _other -> {:error, {:invalid_input, tokens_message()}}
    end
  end

  defp tokens(_value), do: {:error, {:invalid_input, tokens_message()}}

  defp tokens_message, do: "Parameter 'tokens' must be a positive integer"

  ## The call

  defp fetch(%Config{} = config, request, scope) do
    session =
      Common.client().session_context(config, scope.session_id, session_opts(request, config))

    peer = Common.client().peer_context(config, scope.peers.user, [])

    case {session, peer} do
      {{:error, reason}, {:error, _peer_reason}} -> {:error, reason}
      _both -> {:ok, %{session: body(session), peer: body(peer)}}
    end
  end

  defp session_opts(request, %Config{} = config) do
    [summary: true, tokens: request.tokens || config.context_tokens]
  end

  defp body({:ok, body}) when is_map(body), do: body
  defp body(_other), do: %{}

  ## Results

  defp format(parts, scope) do
    summary = summary_of(parts.session)
    representation = representation_of(parts.peer)
    card = card_of(parts.peer)
    messages = messages_of(parts.session)

    sections =
      [
        {"Session summary", summary},
        {"What Honcho knows about the user", representation},
        {"User profile", bullets(card)},
        {"Recent messages", render_messages(messages)}
      ]
      |> Enum.reject(fn {_title, text} -> text in [nil, ""] end)

    %AgentToolResult{
      content: [%TextContent{text: render(sections, scope)}],
      details: %{
        session_id: scope.session_id,
        peer: scope.peers.user,
        summary: summary,
        representation: representation,
        peer_card: card,
        message_count: length(messages)
      }
    }
  end

  defp render([], scope) do
    "Honcho has no stored context for this session yet (#{scope.session_id})."
  end

  defp render(sections, scope) do
    body = Enum.map_join(sections, "\n\n", fn {title, text} -> "## #{title}\n#{text}" end)

    "Honcho context for session #{scope.session_id}:\n\n" <> body
  end

  # Honcho has spelled these differently across API versions, and a context read
  # that silently rendered nothing would look exactly like an empty memory, so
  # each shape it is known to return is matched rather than assumed.
  defp summary_of(%{"summary" => %{"content" => content}}) when is_binary(content), do: content
  defp summary_of(%{"summary" => summary}) when is_binary(summary), do: summary
  defp summary_of(_body), do: nil

  defp representation_of(%{"representation" => value}) when is_binary(value), do: value
  defp representation_of(%{"peer_representation" => value}) when is_binary(value), do: value
  defp representation_of(_body), do: nil

  defp card_of(%{"peer_card" => card}) when is_list(card), do: card
  defp card_of(%{"peer_card" => card}) when is_binary(card), do: String.split(card, "\n")
  defp card_of(_body), do: []

  defp messages_of(%{"messages" => messages}) when is_list(messages) do
    messages |> Enum.filter(&is_map/1) |> Enum.take(-@max_messages)
  end

  defp messages_of(_body), do: []

  defp bullets([]), do: nil

  defp bullets(card) do
    card
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("\n", &("- " <> &1))
  end

  defp render_messages([]), do: nil

  defp render_messages(messages) do
    Enum.map_join(messages, "\n", fn message ->
      peer = Map.get(message, "peer_id") || Map.get(message, "peer") || "unknown"
      content = message |> Map.get("content", "") |> to_string() |> String.trim()

      "#{peer}: #{String.slice(content, 0, @message_max_chars)}"
    end)
  end

  defp not_configured do
    Common.not_configured("there is no stored context to read")
  end

  defp context_only do
    Common.context_only(
      ". What Honcho knows about this user is already in your system prompt — read it there.",
      "query it directly"
    )
  end

  defp failure(message), do: Common.failure(@tool_name, message)
end
