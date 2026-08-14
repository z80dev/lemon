defmodule LemonHoncho.Tools.Reasoning do
  @moduledoc """
  The `honcho_reasoning` tool: ask Honcho's dialectic endpoint about the user.

  This is the expensive tool in the set and the only one that spends inference
  on the server. Honcho reasons over everything it has accumulated about a peer
  and answers in prose, which is worth it for a question whose answer has to be
  *inferred* from many sessions and is never worth it for a question a stored
  excerpt would settle. The description the model sees says exactly that, in
  those terms, because the model is the only thing that can make that choice.

  ## Which peer is asked, and about whom

  The same rule the automatic injection uses (`LemonHoncho.SessionManager`): the
  assistant peer observes the other side in every supported observation mode,
  so it holds the richer view and is asked *about* the user. `target: "ai"`
  flips the question to what the assistant peer knows about itself, which is
  how an agent inspects its own accumulated behaviour rather than the user's.

  ## Modes and configuration

  Registration is unconditional, so the tool exists on every host and reports
  its own state instead of vanishing: an unconfigured Honcho yields a result
  telling the operator which variable to set, and `recall_mode: :context`
  yields a result saying the answer is already in the system prompt. Neither
  raises, and neither fails the turn — see `LemonAgent.Types.AgentTool`.

  ## The question is screened before it leaves

  A model-authored question is in practice often a verbatim paste of what the
  user just said, and this one is sent to a third-party service that reasons
  over it and keeps what it learned. So it goes through
  `LemonHoncho.Egress.screen/2`: clipped to 1,500 characters — the same cut
  `LemonHoncho.Context` applies to the message it embeds in the dialectic
  question — and then withheld entirely if it looks like it carries a
  credential.

  When it is withheld the call is *refused* rather than made without a question,
  because a dialectic call with no question is not this question answered
  vaguely, it is a different question. The refusal is an ordinary result, so the
  turn continues and the model can rephrase; neither it nor any log repeats the
  offending text.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonHoncho.{Config, Egress}
  alias LemonHoncho.Tools.Common

  # The model-facing name, used both in the definition and in the debug line a
  # failed call writes, so a log entry always names a tool the model can see.
  @tool_name "honcho_reasoning"

  @reasoning_levels ~w(minimal low medium high max)
  @targets ~w(user ai)

  # A question for a colleague, not a document to be reasoned over: the same
  # 1,500 characters the automatic dialectic path allows its query.
  @max_query_chars 1_500

  @description """
  Ask Honcho, the long-term memory service, a question about the person you are working with, and get back one \
  synthesized answer rather than raw excerpts. Reach for it when the answer has to be inferred across many past \
  sessions — "how do they like changes explained?", "what have they decided about testing?" — and is not in this \
  conversation. Every call spends an LLM call on Honcho's server, so it is slower and more expensive than the \
  other memory tools: try honcho_search or search_memory first when a stored fact or a quote would settle the \
  question, and use this when it would not. Returns prose, or a note that Honcho has nothing to say yet.\
  """

  @doc """
  The `honcho_reasoning` tool definition.

  `opts` is the tool option list the session builds its tools with; the session
  key, session id, and cwd in it are what scope the question to a conversation.
  """
  @spec tool(keyword()) :: AgentTool.t()
  def tool(opts \\ []) do
    %AgentTool{
      name: @tool_name,
      description: @description,
      label: "Honcho Reasoning",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" =>
              "The question to ask about the user, in plain language, as you would ask a colleague who knows them."
          },
          "reasoning_level" => %{
            "type" => "string",
            "enum" => @reasoning_levels,
            "description" =>
              "How much reasoning Honcho spends on the answer. Higher costs more and takes longer; " <>
                "defaults to the configured level."
          },
          "target" => %{
            "type" => "string",
            "enum" => @targets,
            "description" =>
              ~s|Who the question is about: "user" (the default) or "ai" to ask what Honcho has learned | <>
                "about this assistant's own behaviour."
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

  @doc "Runs `honcho_reasoning` with no session options; see `execute/5`."
  @spec execute(String.t(), map(), reference() | nil, function() | nil) :: AgentToolResult.t()
  def execute(tool_call_id, params, signal, on_update) do
    execute(tool_call_id, params, signal, on_update, [])
  end

  @doc """
  Runs `honcho_reasoning`, scoped to the session named in `opts`.

  Always returns an `t:LemonAgent.Types.AgentToolResult.t/0`: an unconfigured
  integration, a rejected parameter, and a Honcho outage are all reported as
  results the model can read rather than as errors that end the turn.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, keyword()) ::
          AgentToolResult.t()
  def execute(_tool_call_id, params, _signal, _on_update, opts) do
    config = Config.load()

    with :ok <- Common.gate(config),
         {:ok, request} <- normalize(params, config),
         scope = Common.scope(config, opts),
         {:ok, answer} <- ask(config, request, scope) do
      format(answer, request, scope)
    else
      {:error, :not_configured} -> not_configured()
      {:error, :context_only} -> context_only()
      {:error, {:invalid_input, message}} -> failure(message)
      {:error, {:withheld, parameter}} -> withheld(parameter)
      {:error, {:unauthorized, _body}} -> failure(Common.unauthorized_message())
      {:error, {:api_error, status, body}} -> failure(Common.api_message(status, body))
      {:error, reason} -> failure("Honcho reasoning failed: #{inspect(reason)}")
    end
  end

  ## Parameters

  defp normalize(params, %Config{} = config) do
    with {:ok, query} <- query(Map.get(params, "query")),
         {:ok, level} <- reasoning_level(Map.get(params, "reasoning_level"), config),
         {:ok, target} <- target(Map.get(params, "target")) do
      {:ok, %{query: query, reasoning_level: level, target: target}}
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
  # what `details.query` echoes is exactly the string that went on the wire.
  defp screen(trimmed) do
    case Egress.screen(trimmed, @max_query_chars) do
      nil -> {:error, {:withheld, "query"}}
      screened -> {:ok, screened}
    end
  end

  defp reasoning_level(nil, %Config{} = config), do: {:ok, config.reasoning_level}

  defp reasoning_level(value, %Config{} = config) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> {:ok, config.reasoning_level}
      level when level in @reasoning_levels -> {:ok, String.to_existing_atom(level)}
      _other -> {:error, {:invalid_input, enum_message("reasoning_level", @reasoning_levels)}}
    end
  end

  defp reasoning_level(_value, _config) do
    {:error, {:invalid_input, enum_message("reasoning_level", @reasoning_levels)}}
  end

  defp target(nil), do: {:ok, "user"}

  defp target(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> {:ok, "user"}
      target when target in @targets -> {:ok, target}
      _other -> {:error, {:invalid_input, enum_message("target", @targets)}}
    end
  end

  defp target(_value), do: {:error, {:invalid_input, enum_message("target", @targets)}}

  defp enum_message(name, allowed) do
    "Parameter '#{name}' must be one of: #{Enum.join(allowed, ", ")}"
  end

  ## The call

  defp ask(%Config{} = config, request, scope) do
    {peer, peer_opts} = dialectic_peer(config, scope, request.target)

    opts =
      Keyword.merge(peer_opts,
        session_id: scope.session_id,
        reasoning_level: request.reasoning_level
      )

    Common.client().chat(config, peer, request.query, opts)
  end

  # Mirrors `LemonHoncho.SessionManager`'s choice so a tool call and an injected
  # block are answers from the same peer. The assistant peer is the one asked
  # about the user: it observes the other side in every supported observation
  # mode (`:directional` and `:unified` both set `ai.observe_others` to `true`),
  # so it holds the view of the user a question about the user is answered from.
  # Asking about the assistant itself is the `"ai"` clause above.
  defp dialectic_peer(_config, scope, "ai"), do: {scope.peers.ai, []}

  defp dialectic_peer(%Config{}, scope, _user), do: {scope.peers.ai, [target: scope.peers.user]}

  ## Results

  defp format(nil, request, scope) do
    text = """
    Honcho has nothing to say about that yet. This is normal for a peer it has \
    not observed much of: ask the user directly, and the answer will be there \
    next time.
    """

    result(text, request, scope, nil)
  end

  defp format(answer, request, scope) when is_binary(answer) do
    result(answer, request, scope, answer)
  end

  defp result(text, request, scope, answer) do
    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        query: request.query,
        target: request.target,
        reasoning_level: request.reasoning_level,
        session_id: scope.session_id,
        answer: answer
      }
    }
  end

  defp not_configured do
    Common.not_configured("there is nothing to reason over")
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
    API key, token, or private key — so it was not sent to Honcho and no question \
    was asked. Nothing was stored and nothing was logged. Rephrase it without the \
    credential material and call this tool again.
    """

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{error: :withheld, parameter: parameter}
    }
  end

  defp failure(message), do: Common.failure(@tool_name, message)
end
