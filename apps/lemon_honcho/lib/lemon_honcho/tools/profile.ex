defmodule LemonHoncho.Tools.Profile do
  @moduledoc """
  The `honcho_profile` tool: read or overwrite the user's Honcho peer card.

  A peer card is the short list of durable facts Honcho keeps about a person
  and injects into every session. It is the most valuable thing in this
  integration and the easiest to damage, because Honcho's card API is a
  *replace*, not an append: writing three lines to a card that had ten leaves
  three. That single fact shapes everything in this module.

  ## Writes are stated as writes

  The description the model sees says in plain words that `card` replaces the
  entire card and that omitted lines are deleted, and tells it to read the card
  before writing one. The result of a write echoes the exact lines that were
  stored, so a model that dropped a line by accident can see that it did rather
  than infer it from silence.

  For the same reason an empty `card` is rejected rather than obeyed. `[]` is
  what a model produces when it means "I have nothing to add", and honouring it
  would erase a profile built over months in response to a mistake. Clearing a
  card is a deliberate act and belongs to the operator, not to a tool call.

  ## Which peer

  The user peer of the current session, as the session manager recorded it,
  falling back to `config.user_peer`. The assistant's own card is not writable
  here: an agent editing its own stored identity is a different operation with
  different consequences, and conflating the two behind one `target` parameter
  would make an accidental self-edit a one-word mistake.

  ## Read and write are gated differently

  `LEMON_HONCHO_SAVE_MESSAGES=false` is documented as making the whole
  integration read-only, so it has to be enforced at every point that writes to
  Honcho's store and not only at the message upload it was named after. Writing
  a card is the most destructive write this integration has — it replaces what
  is there — so with uploads off the write is refused with a plain statement and
  no call is made. Reading the card keeps working: a read-only integration that
  cannot read is not read-only, it is off.

  ## Every line is screened before it leaves

  A card line is the most durable thing this integration writes: a
  human-readable fact in a third-party store, recalled into every future
  session, so a credential pasted into one persists longer than anywhere else
  Honcho is reachable from. Each line therefore goes through
  `LemonHoncho.Egress.screen/2` before the write.

  A line that trips the screen refuses the *whole* write, and this is the one
  place where dropping the offending item would have been actively destructive:
  a write is a replace, so sending the remaining lines would delete the withheld
  one from the stored card as a side effect of a safety check. The refusal is an
  ordinary result, so the turn continues and the model can rephrase; neither it
  nor any log repeats the offending text.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonHoncho.{Config, Egress}
  alias LemonHoncho.Tools.Common

  # The model-facing name, used both in the definition and in the debug line a
  # failed call writes, so a log entry always names a tool the model can see.
  @tool_name "honcho_profile"

  @max_lines 50
  @max_line_chars 500

  @description """
  Read or overwrite the user's Honcho profile card — the short list of durable facts about them that is recalled \
  into every future session. Called with no arguments it returns the current card. Called with `card`, it REPLACES \
  the whole card with the lines you pass: any line currently on the card and missing from your list is deleted, so \
  read the card first and send back the lines you want to keep along with the new one. Write only what the user has \
  actually told you, phrased so it still makes sense months from now, and leave task-specific detail out — the card \
  is not scratch space. The result echoes exactly what was stored.\
  """

  @doc """
  The `honcho_profile` tool definition.

  `opts` is the session's tool option list; its session key identifies which
  peer's card is read or written.
  """
  @spec tool(keyword()) :: AgentTool.t()
  def tool(opts \\ []) do
    %AgentTool{
      name: @tool_name,
      description: @description,
      label: "Honcho Profile",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "card" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "The complete new card, one durable fact per line (max #{@max_lines} lines). " <>
                "Omit to read the current card. Passing this REPLACES every line that is stored now."
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

  @doc "Runs `honcho_profile` with no session options; see `execute/5`."
  @spec execute(String.t(), map(), reference() | nil, function() | nil) :: AgentToolResult.t()
  def execute(tool_call_id, params, signal, on_update) do
    execute(tool_call_id, params, signal, on_update, [])
  end

  @doc """
  Runs `honcho_profile`, against the user peer of the session named in `opts`.

  Always returns an `t:LemonAgent.Types.AgentToolResult.t/0`. A rejected `card`
  is reported without any write having been attempted, and so is a write made
  while `save_messages?` is false.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, keyword()) ::
          AgentToolResult.t()
  def execute(_tool_call_id, params, _signal, _on_update, opts) do
    config = Config.load()

    with :ok <- Common.gate(config),
         {:ok, request} <- normalize(params),
         :ok <- writable(config, request),
         scope = Common.scope(config, opts),
         {:ok, card} <- apply_card(config, request, scope) do
      format(card, request, scope)
    else
      {:error, :not_configured} -> not_configured()
      {:error, :context_only} -> context_only()
      {:error, :uploads_disabled} -> uploads_disabled()
      {:error, {:withheld, parameter}} -> withheld(parameter)
      {:error, {:invalid_input, message}} -> failure(message)
      {:error, {:unauthorized, _body}} -> failure(Common.unauthorized_message())
      {:error, {:api_error, status, body}} -> failure(Common.api_message(status, body))
      {:error, reason} -> failure("Honcho profile request failed: #{inspect(reason)}")
    end
  end

  ## Parameters

  defp normalize(params) do
    case card(Map.get(params, "card")) do
      {:ok, nil} -> {:ok, %{action: :read, card: nil}}
      {:ok, lines} -> {:ok, %{action: :write, card: lines}}
      error -> error
    end
  end

  defp card(nil), do: {:ok, nil}

  defp card([]) do
    {:error,
     {:invalid_input,
      "Parameter 'card' cannot be an empty list: that would erase the whole profile. " <>
        "Omit 'card' to read it instead."}}
  end

  defp card(lines) when is_list(lines) do
    trimmed =
      lines
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      length(trimmed) != length(lines) ->
        {:error, {:invalid_input, entries_message()}}

      length(trimmed) > @max_lines ->
        {:error, {:invalid_input, too_many_message()}}

      Enum.any?(trimmed, &(String.length(&1) > @max_line_chars)) ->
        {:error, {:invalid_input, too_long_message()}}

      true ->
        screen(trimmed)
    end
  end

  defp card(_value),
    do: {:error, {:invalid_input, "Parameter 'card' must be an array of strings"}}

  # Over-long lines are rejected above rather than clipped, so the screen here
  # never has anything left to clip and is running for the credential check
  # alone. One bad line refuses the whole write; see the moduledoc for why
  # dropping it would be worse than refusing.
  defp screen(lines) do
    screened = Enum.map(lines, &Egress.screen(&1, @max_line_chars))

    if Enum.any?(screened, &is_nil/1) do
      {:error, {:withheld, "card"}}
    else
      {:ok, screened}
    end
  end

  defp entries_message do
    "Every entry in 'card' must be a non-empty string"
  end

  defp too_many_message do
    "Parameter 'card' may hold at most #{@max_lines} lines"
  end

  defp too_long_message do
    "Each line of 'card' must be at most #{@max_line_chars} characters"
  end

  ## The call

  defp apply_card(%Config{} = config, %{action: :read}, scope) do
    Common.client().get_peer_card(config, scope.peers.user, [])
  end

  defp apply_card(%Config{} = config, %{action: :write, card: card}, scope) do
    case Common.client().set_peer_card(config, scope.peers.user, card, []) do
      # Honcho does not always echo the stored card back; what was sent is then
      # what is stored, and reporting it is better than reporting nothing.
      {:ok, nil} -> {:ok, card}
      other -> other
    end
  end

  ## Results

  defp format(nil, %{action: :read}, scope) do
    text = "Honcho has no profile card for #{scope.peers.user} yet."

    result(text, :read, scope, nil)
  end

  defp format(card, %{action: :read}, scope) do
    text = "Honcho profile card for #{scope.peers.user}:\n\n" <> bullets(card)

    result(text, :read, scope, card)
  end

  defp format(card, %{action: :write}, scope) do
    text =
      "Replaced the Honcho profile card for #{scope.peers.user}. It now reads:\n\n" <>
        bullets(card || [])

    result(text, :write, scope, card)
  end

  defp bullets([]), do: "(empty)"

  defp bullets(card) when is_list(card) do
    Enum.map_join(card, "\n", &("- " <> to_string(&1)))
  end

  defp result(text, action, scope, card) do
    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{action: action, peer: scope.peers.user, session_id: scope.session_id, card: card}
    }
  end

  defp not_configured do
    Common.not_configured("there is no profile card to read or write")
  end

  defp context_only do
    Common.context_only(
      ". The user's profile card is already in your system prompt — read it there.",
      "read or edit it directly"
    )
  end

  defp uploads_disabled do
    text = """
    Honcho uploads are disabled (LEMON_HONCHO_SAVE_MESSAGES=false), so the \
    profile card was not replaced and nothing in Honcho's store changed. \
    Reading stays available: call this tool with no arguments to see the \
    current card. Set LEMON_HONCHO_SAVE_MESSAGES=true to edit it.
    """

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{error: :uploads_disabled, action: :write}
    }
  end

  # A refusal, not an error: the model can only rephrase if the turn survives.
  # The parameter is named and the offending line is not — repeating it here
  # would put it in the transcript, which is the one place it has not reached
  # yet, and would defeat the point of never having sent it.
  defp withheld(parameter) do
    text = """
    One of the lines in '#{parameter}' looks like it carries a credential — a \
    password, API key, token, or private key — so nothing was sent to Honcho and \
    the profile card was not replaced. The stored card is untouched, and nothing \
    was logged. A card is a durable, recalled-everywhere record and is the wrong \
    place for a secret: send the card again without that line.
    """

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{error: :withheld, parameter: parameter}
    }
  end

  defp failure(message), do: Common.failure(@tool_name, message)

  ## The write gate

  # Checked after the parameters are understood rather than alongside the other
  # gates, so a malformed card is still reported as malformed and only a write
  # that would otherwise have gone through is refused here.
  defp writable(%Config{} = config, %{action: :write}), do: Common.gate(config, :write)

  defp writable(%Config{}, _request), do: :ok
end
