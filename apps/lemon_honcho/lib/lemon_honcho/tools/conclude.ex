defmodule LemonHoncho.Tools.Conclude do
  @moduledoc """
  The `honcho_conclude` tool: record, search, or retract explicit conclusions.

  Most of what Honcho believes about a person it inferred on its own. A
  *conclusion* is the other kind: a fact stated outright, written by the
  assistant peer about the user peer and kept alongside the inferred ones. This
  tool is how an agent says "this is settled, remember it", how it finds what
  has already been settled, and how a stored fact gets taken back.

  ## Exactly one action per call

  `conclusion` creates, `query` searches, and `delete_id` deletes; passing more
  than one or none of them is an invalid-input error rather than a guess. Create
  and delete are opposite operations on durable state, so a call that supplied
  both would have to be resolved by a precedence rule the model never saw, and
  one that supplied neither would most likely be a model that meant to write
  something and dropped the text. Search is folded into the same rule rather
  than given its own tool because the three are one workflow — search to find an
  id, delete that id — and a model that has all three in front of it under one
  name is less likely to record a duplicate of something already stored.

  ## Scope and direction

  A conclusion is recorded as the assistant peer observing the user peer, and
  tagged with the current Honcho session so it can be traced back to the
  conversation that produced it. A search is filtered to that same pair, so what
  comes back is what a create here would have written. The peers come from the
  session manager, so a conclusion written by a tool call and one derived from
  injected context land on the same pair.

  ## Read and write are gated differently

  `LEMON_HONCHO_SAVE_MESSAGES=false` is documented as making the whole
  integration read-only, so it has to be enforced at every point that writes to
  Honcho's store and not only at the message upload it was named after. Creating
  a conclusion and deleting one are both writes — deleting is a change to their
  store just as much as creating is — and both answer with a plain statement
  that uploads are off rather than calling the API. `query` is a read and keeps
  working, because a read-only integration that cannot read is not read-only,
  it is off.

  ## Both texts are screened before they leave

  `conclusion` and `query` both go through `LemonHoncho.Egress.screen/2` — the
  clip, then the credential check — and a text that trips it is refused rather
  than sent. A conclusion earns the screen twice over: it is a durable,
  human-readable fact written into a third-party store and recalled into every
  future session, which is exactly where a pasted credential does the most
  lasting damage, and unlike a search it cannot be undone by not looking.

  The refusal is an ordinary result, so the turn continues and the model can
  rephrase; neither it nor any log repeats the offending text. `delete_id` is
  not screened: it is an opaque id the model read back from a `query`, and
  clipping an identifier would silently address the wrong row rather than
  protect anything.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonHoncho.{Config, Egress}
  alias LemonHoncho.Tools.Common

  # The model-facing name, used both in the definition and in the debug line a
  # failed call writes, so a log entry always names a tool the model can see.
  @tool_name "honcho_conclude"

  @max_conclusion_chars 2_000
  @default_top_k 10
  @max_top_k 50
  @excerpt_max_chars 1_000

  # A phrase describing the idea to look for, matched semantically — the same
  # figure the other Honcho search paths allow their query.
  @max_query_chars 1_500

  # The three mutually exclusive actions, in the order they are reported in the
  # "exactly one" message. Named once so the check and the message cannot drift.
  @actions ["conclusion", "query", "delete_id"]

  @description """
  Record, search, or remove explicit conclusions about the user in Honcho — facts stated outright rather than ones \
  Honcho inferred for itself. Pass `conclusion` to store a durable observation the user has confirmed ("never \
  deploys on Fridays", "wants tests written before the fix"), `query` to semantically search the conclusions already \
  stored and get them back with their ids, or `delete_id` to remove one by id, which is how something recorded in \
  error or a piece of personal information gets retracted. Exactly one of the three per call. Search before you \
  record, so you do not store a second copy of a fact that is already there, and to find the id you need in order to \
  delete one. Conclusions are recalled in every future session, so record what will still be true next month and \
  leave what is only true of this task out.\
  """

  @doc """
  The `honcho_conclude` tool definition.

  `opts` is the session's tool option list; its session key decides which
  Honcho session a created conclusion is tagged with, and which peers a search
  is filtered to.
  """
  @spec tool(keyword()) :: AgentTool.t()
  def tool(opts \\ []) do
    %AgentTool{
      name: @tool_name,
      description: @description,
      label: "Honcho Conclude",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "conclusion" => %{
            "type" => "string",
            "description" =>
              "The fact to record about the user, as one self-contained sentence that will still make sense " <>
                "without this conversation around it."
          },
          "query" => %{
            "type" => "string",
            "description" =>
              "Search the conclusions already stored about this user and return the matches with their ids. " <>
                "Matched semantically, so a phrase describing the idea works better than keywords."
          },
          "top_k" => %{
            "type" => "integer",
            "description" =>
              "Maximum number of matches to return for 'query' (default: #{@default_top_k}, max: #{@max_top_k}). " <>
                "Ignored by the other actions."
          },
          "delete_id" => %{
            "type" => "string",
            "description" =>
              "Id of a stored conclusion to delete, as returned by a 'query' search. Mutually exclusive with " <>
                "'conclusion' and 'query'."
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

  @doc "Runs `honcho_conclude` with no session options; see `execute/5`."
  @spec execute(String.t(), map(), reference() | nil, function() | nil) :: AgentToolResult.t()
  def execute(tool_call_id, params, signal, on_update) do
    execute(tool_call_id, params, signal, on_update, [])
  end

  @doc """
  Runs `honcho_conclude`, scoped to the session named in `opts`.

  Always returns an `t:LemonAgent.Types.AgentToolResult.t/0`. Nothing is
  written when the parameters do not name exactly one action, and nothing is
  written at all when `save_messages?` is false.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, keyword()) ::
          AgentToolResult.t()
  def execute(_tool_call_id, params, _signal, _on_update, opts) do
    config = Config.load()

    with :ok <- Common.gate(config),
         {:ok, request} <- normalize(params),
         :ok <- writable(config, request),
         scope = Common.scope(config, opts),
         {:ok, body} <- apply_action(config, request, scope) do
      format(request, scope, body)
    else
      {:error, :not_configured} -> not_configured()
      {:error, :context_only} -> context_only()
      {:error, {:uploads_disabled, action}} -> uploads_disabled(action)
      {:error, {:invalid_input, message}} -> failure(message)
      {:error, {:withheld, parameter}} -> withheld(parameter)
      {:error, {:unauthorized, _body}} -> failure(Common.unauthorized_message())
      {:error, {:api_error, status, body}} -> failure(Common.api_message(status, body))
      {:error, reason} -> failure("Honcho conclusion request failed: #{inspect(reason)}")
    end
  end

  ## Parameters

  defp normalize(params) do
    with {:ok, values} <- strings(params),
         {:ok, top_k} <- top_k(Map.get(params, "top_k")),
         {:ok, name} <- single_action(values) do
      request(name, values, top_k)
    end
  end

  # Every action parameter is read and type-checked before the mutual-exclusion
  # rule runs, so `delete_id: 7` is reported as a type error rather than as
  # "you named no action" — the model can fix the first and would be misled by
  # the second.
  defp strings(params) do
    Enum.reduce_while(@actions, {:ok, %{}}, fn name, {:ok, acc} ->
      case optional_string(Map.get(params, name)) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, _reason} -> {:halt, {:error, {:invalid_input, string_message(name)}}}
      end
    end)
  end

  defp single_action(values) do
    case Enum.filter(@actions, &is_binary(values[&1])) do
      [name] -> {:ok, name}
      _none_or_several -> {:error, {:invalid_input, exactly_one_message()}}
    end
  end

  # An over-long conclusion is rejected rather than clipped, because half a
  # recorded fact reads as a whole one forever after. The screen that follows
  # therefore never has anything left to clip, and is there for the credential
  # check alone.
  defp request("conclusion", values, _top_k) do
    text = values["conclusion"]

    if byte_size(text) > @max_conclusion_chars do
      {:error,
       {:invalid_input,
        "Parameter 'conclusion' must be at most #{@max_conclusion_chars} characters"}}
    else
      screen(:create, :conclusion, text, @max_conclusion_chars, [])
    end
  end

  defp request("delete_id", values, _top_k) do
    {:ok, blank_request(:delete, delete_id: values["delete_id"])}
  end

  defp request("query", values, top_k) do
    screen(:query, :query, values["query"], @max_query_chars, top_k: top_k)
  end

  # One gate for both texts this tool puts on the wire; `field` is the parameter
  # it came from, so a refusal can say which one it was without saying what it
  # said.
  defp screen(action, field, text, max_chars, extra) do
    case Egress.screen(text, max_chars) do
      nil -> {:error, {:withheld, Atom.to_string(field)}}
      screened -> {:ok, blank_request(action, [{field, screened} | extra])}
    end
  end

  # One shape for all three actions, so `details` and the formatters can read
  # every field without knowing which action produced the request.
  defp blank_request(action, fields) do
    %{action: action, conclusion: nil, delete_id: nil, query: nil, top_k: nil}
    |> Map.merge(Map.new(fields))
  end

  # A blank string is treated as absent rather than as an action, so
  # `conclusion: ""` fails with "name exactly one" instead of writing an empty
  # fact that Honcho would then try to interpret.
  defp optional_string(nil), do: {:ok, nil}

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp optional_string(_value), do: {:error, :not_a_string}

  defp top_k(nil), do: {:ok, @default_top_k}
  defp top_k(value) when is_integer(value) and value > 0, do: {:ok, min(value, @max_top_k)}

  defp top_k(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {parsed, ""} -> top_k(parsed)
      _other -> {:error, {:invalid_input, top_k_message()}}
    end
  end

  defp top_k(_value), do: {:error, {:invalid_input, top_k_message()}}

  defp top_k_message, do: "Parameter 'top_k' must be a positive integer"

  defp string_message(name), do: "Parameter '#{name}' must be a string"

  defp exactly_one_message do
    "Pass exactly one of 'conclusion' (to record a fact), 'query' (to search stored conclusions), or " <>
      "'delete_id' (to remove one) — not none of them and not more than one"
  end

  ## The call

  defp apply_action(%Config{} = config, %{action: :create} = request, scope) do
    conclusion = %{
      observer_id: scope.peers.ai,
      observed_id: scope.peers.user,
      content: request.conclusion,
      session_id: scope.session_id
    }

    Common.client().create_conclusions(config, [conclusion])
  end

  defp apply_action(%Config{} = config, %{action: :delete} = request, _scope) do
    Common.client().delete_conclusion(config, request.delete_id)
  end

  # Filtered to the same observer/observed pair a create here would write, so a
  # search answers "is this already recorded" about the conclusions this tool
  # owns rather than about every conclusion in the workspace.
  defp apply_action(%Config{} = config, %{action: :query} = request, scope) do
    Common.client().query_conclusions(config, request.query,
      observer_id: scope.peers.ai,
      observed_id: scope.peers.user,
      top_k: request.top_k
    )
  end

  ## Results

  defp format(%{action: :create} = request, scope, _body) do
    text = """
    Recorded a conclusion about #{scope.peers.user}:

    #{request.conclusion}
    """

    result(text, request, scope, %{})
  end

  defp format(%{action: :delete} = request, scope, _body) do
    result("Deleted conclusion #{request.delete_id}.", request, scope, %{})
  end

  defp format(%{action: :query} = request, scope, body) do
    case hits(body) do
      [] ->
        text = "No stored conclusions about #{scope.peers.user} match #{inspect(request.query)}."

        result(text, request, scope, %{count: 0, excerpts: []})

      hits ->
        excerpts = Enum.map(hits, &excerpt/1)

        text = """
        #{length(excerpts)} stored conclusion(s) matching #{inspect(request.query)}:

        #{Enum.join(excerpts, "\n---\n")}

        Pass one of the ids above as 'delete_id' to remove that conclusion.
        """

        result(text, request, scope, %{count: length(excerpts), excerpts: excerpts})
    end
  end

  defp hits(body) when is_list(body), do: body
  defp hits(_body), do: []

  # The id is what makes a result actionable — it is the only way back to a
  # delete — so it leads the excerpt, and a hit whose id Honcho spells under a
  # key this does not know is still shown rather than dropped.
  defp excerpt(hit) when is_map(hit) do
    id = first_string(hit, ["id", "conclusion_id", "public_id"])
    stamp = first_string(hit, ["created_at", "createdAt", "timestamp"])
    text = hit |> first_string(["content", "conclusion", "text"]) |> clip()

    case Enum.reject([id, stamp], &is_nil/1) do
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

  defp result(text, request, scope, extra) do
    details = %{
      action: request.action,
      conclusion: request.conclusion,
      delete_id: request.delete_id,
      query: request.query,
      top_k: request.top_k,
      observer: scope.peers.ai,
      observed: scope.peers.user,
      session_id: scope.session_id
    }

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: Map.merge(details, extra)
    }
  end

  defp not_configured do
    Common.not_configured("there is nowhere to record a conclusion")
  end

  defp context_only do
    Common.context_only(
      " and nothing was recorded.",
      "write conclusions from a tool call"
    )
  end

  defp uploads_disabled(action) do
    text = """
    Honcho uploads are disabled (LEMON_HONCHO_SAVE_MESSAGES=false), so #{disabled_effect(action)} \
    and nothing in Honcho's store changed. Reading stays available: search the stored conclusions \
    with 'query' instead. Set LEMON_HONCHO_SAVE_MESSAGES=true to write again.
    """

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{error: :uploads_disabled, action: action}
    }
  end

  defp disabled_effect(:create), do: "the conclusion was not recorded"
  defp disabled_effect(:delete), do: "the conclusion was not deleted"

  # A refusal, not an error: the model can only rephrase if the turn survives.
  # The parameter is named and the value is not — repeating it here would put it
  # in the transcript, which is the one place it has not reached yet.
  defp withheld(parameter) do
    text = """
    The '#{parameter}' you passed looks like it carries a credential — a password, \
    API key, token, or private key — so it was not sent to Honcho and \
    #{withheld_effect(parameter)}. Nothing in Honcho's store changed and nothing was \
    logged. Rephrase it without the credential material and call this tool again.
    """

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{error: :withheld, parameter: parameter}
    }
  end

  defp withheld_effect("conclusion"), do: "the conclusion was not recorded"
  defp withheld_effect("query"), do: "no search ran"

  defp failure(message), do: Common.failure(@tool_name, message)

  ## The write gate

  # Checked after the parameters are understood rather than alongside the other
  # gates, so the answer can name the action that was refused. Deleting counts
  # as a write: it changes Honcho's store, which is exactly what a read-only
  # integration promises not to do.
  defp writable(%Config{} = config, %{action: action}) when action in [:create, :delete] do
    case Common.gate(config, :write) do
      {:error, :uploads_disabled} -> {:error, {:uploads_disabled, action}}
      other -> other
    end
  end

  defp writable(%Config{}, _request), do: :ok
end
