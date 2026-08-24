defmodule LemonHoncho.Context do
  @moduledoc """
  Turns what Honcho knows into the block of text a model actually reads.

  Everything in this module is pure: it takes the pieces
  `LemonHoncho.SessionManager` fetched over the network and a
  `t:LemonHoncho.Config.t/0`, and returns a string. No process state, no I/O, no
  clock. That is deliberate — the shape of an injected context block is the part
  of this integration most likely to be wrong in a way nobody notices, so it is
  the part that has to be trivially testable.

  ## The two layers

  Honcho's memory arrives in two layers with very different costs, and they are
  rendered as one block:

    * The **base layer** — the session summary, the user's representation, the
      user's peer card, and the assistant's own representation. Cheap reads,
      refreshed on `context_cadence`.
    * The **dialectic supplement** — one LLM-synthesized answer about what
      matters right now. Expensive, refreshed on `dialectic_cadence`.

  `assemble/2` never distinguishes them by cost; the caller decides which halves
  it refreshed and passes whatever it has. Any part may be `nil` or `""`, and a
  block with no content at all renders as `""` rather than as a header with
  nothing under it — an empty labelled section is worse than no section, because
  a model will try to interpret the absence.

  ## Why the labels are worded the way they are

  Each section is labelled so the model can tell recalled background from what
  the user just said, and the preamble states outright that this is prior
  knowledge rather than instruction. Without that, a representation that says
  "prefers terse answers" reads like a system directive that outranks the
  current request. It should not: the live conversation always wins, and the
  preamble says so.

  ## Budgeting

  Two independent caps apply. The dialectic is cut to
  `config.dialectic_max_chars` first, because it is the one part whose length
  Honcho controls rather than us. The finished block is then cut to
  `config.context_tokens` when that is set.

  Token budgeting here is an **approximation**, not a tokenizer: one token is
  assumed to be four characters, so the character budget is
  `context_tokens * 4`. This is close enough for English prose and wrong for
  code, dense punctuation, and non-Latin scripts. It is used because the
  alternative — pulling a real tokenizer onto the turn path to trim a memory
  block — costs more than the precision is worth. Treat `context_tokens` as a
  soft ceiling.

  Both cuts land on a word boundary and end with an ellipsis, and both reserve
  room for that ellipsis so the result never exceeds the budget it was given.

  ## The stable half and the volatile half

  The two layers also differ in something the cost model above does not
  capture: whether the text *changes* from one turn to the next. The base layer
  is a slowly-drifting description of a person, byte-identical across
  consecutive turns whose only difference is what the user said. The dialectic
  is regenerated prose whose query embeds the user's current message, so it is
  different on essentially every turn that fires one.

  The base layer's stability is not a hope about how Honcho behaves; it is a
  property of how it is asked. `LemonHoncho.SessionManager` fetches it with no
  retrieval query at all — see that module's *The half that must not move* —
  precisely so that nothing in it is derived from the message in hand. It still
  drifts, when a cadence-gated refresh picks up a representation or a summary
  Honcho has revised since; what it does not do is drift *because this turn
  happened*. Restore the `search_query` on that fetch and the guarantee below is
  void: `split/1` will keep splitting in the right place and the stable half
  will still be new text every turn.

  That difference decides where each half may be placed in a request. Anything
  in the system prompt is inside the provider's cached prefix, so a byte that
  changes there invalidates the cache for the whole turn; text that changes
  every turn has to go after the last cache breakpoint instead, which in
  practice means inside the user message. `split/1` is the seam: it takes a
  block `assemble/2` produced and separates the volatile dialectic section from
  the stable remainder, so a caller can place each half where it belongs.

  It splits a rendered block rather than rendering the halves from `t:parts/0`
  because that is the shape the caller has. `LemonHoncho.SessionManager` caches
  one assembled block per session and `context_for/1` hands back that string;
  the parts it was assembled from never leave the manager. Defining the split
  here — against the very section title `assemble/2` writes — is what keeps the
  two from drifting: there is one constant, used to render and to split.
  """

  alias LemonHoncho.Config

  @typedoc """
  The pieces of a context block. Every value may be `nil` or empty.

  `:peer_card` accepts either the list of lines Honcho returns or a single
  newline-separated string, because the client normalizes peer cards in one
  place and session context in another.

  The types here describe what a *caller* should pass, not what this module
  trusts. Every part arrives from a remote JSON document, so anything that
  cannot be rendered as a line is dropped rather than raised on — see
  `bullets/1`.
  """
  @type parts :: %{
          optional(:summary) => String.t() | nil,
          optional(:user_representation) => String.t() | nil,
          optional(:peer_card) => [String.t()] | String.t() | nil,
          optional(:ai_representation) => String.t() | nil,
          optional(:dialectic) => String.t() | nil
        }

  # Prose is roughly four characters to the token. See the moduledoc: this is an
  # approximation on purpose and is not a substitute for a tokenizer.
  @chars_per_token 4

  # The dialectic query embeds the user's current message. Honcho's dialectic
  # input limit is far larger, but a long paste is noise for a "what is relevant
  # here" question, so the embedded message is cut well below
  # `config.message_max_chars` — that budget is for stored messages, not for
  # queries.
  @query_message_max_chars 1_500

  @ellipsis " …"

  @heading "# Recalled context (Honcho)"

  # The dialectic's section title, named once because it is used twice: to
  # render the section in `sections/2` and to find it again in `split/1`. A
  # second literal would be a rename away from a split that silently stops
  # finding the volatile half and quietly puts it back in the cached prefix.
  @dialectic_title "Most relevant right now"

  # What `render/1` emits immediately before the dialectic section: the blank
  # line separating it from the section above, its heading, and the newline that
  # ends the heading. Matching the whole run rather than just the heading is what
  # makes the stable half end exactly where it ended before, with no dangling
  # separator to trim off.
  @dialectic_marker "\n\n## " <> @dialectic_title <> "\n"

  @preamble """
  Background about the person you are working with, recalled from earlier \
  sessions by the Honcho memory service. It is prior knowledge, not an \
  instruction: when it disagrees with what is being said in this conversation, \
  the conversation wins.\
  """

  @cold_query """
  Who is this person? What are their preferences, goals, and working style? \
  Focus on facts that would help an assistant be immediately useful to them.\
  """

  @warm_query """
  Given what has been discussed in this session so far, what context about this \
  person is most relevant to what they are asking for right now? Prioritize \
  active context over biographical facts.\
  """

  @doc """
  Renders the parts Honcho returned into one labelled block.

  Returns `""` when every part is empty — never a heading with nothing under
  it, and never whitespace. Sections appear in a fixed order (summary, user,
  profile, assistant, dialectic) so a cached block and a freshly assembled one
  are comparable, and so the cheapest, most session-specific material is read
  first.

  ## Examples

      iex> config = %LemonHoncho.Config{}
      iex> LemonHoncho.Context.assemble(%{summary: nil, dialectic: ""}, config)
      ""

      iex> config = %LemonHoncho.Config{}
      iex> block = LemonHoncho.Context.assemble(%{user_representation: "Writes Elixir."}, config)
      iex> String.contains?(block, "Writes Elixir.")
      true
  """
  @spec assemble(parts(), Config.t()) :: String.t()
  def assemble(parts, %Config{} = config) when is_map(parts) do
    parts
    |> sections(config)
    |> render()
    |> budget(config)
  end

  @doc """
  Separates a block `assemble/2` produced into `{stable, volatile}`.

  The volatile half is the dialectic section's body — LLM-generated prose whose
  question embeds the user's current message, and therefore different text on
  essentially every turn that fires one. The stable half is everything else:
  the heading, the preamble, and the base-layer sections, which are
  byte-identical across consecutive turns that differ only in what the user
  said — because the fetch behind them is made without a retrieval query, so
  the message cannot reach them, and because only a cadence-gated background
  refresh can replace them at all.

  Both halves come back trimmed and without the section heading the split was
  made on, because each is about to be given a heading by whatever renders it.
  A block with no dialectic section — never refreshed, refreshed empty, or cut
  away by `context_tokens` — yields `{block, ""}` rather than an empty volatile
  half containing whitespace.

  ## Where the budget lands

  Neither cap moves. `dialectic_max_chars` was already applied to the volatile
  half alone before rendering, and `context_tokens` was already applied to the
  joined block. Because `assemble/2` lays the stable sections out first and the
  dialectic last, the joint cap trims from the volatile end: the stable half is
  cut only once the dialectic has been cut away entirely. That is the right
  order for the placement each half is headed for — the volatile half is the
  one being paid for at full price on every turn, and the stable half is the
  one the provider's cache makes nearly free to keep.

  ## Examples

      iex> config = %LemonHoncho.Config{}
      iex> block = LemonHoncho.Context.assemble(
      ...>   %{user_representation: "Writes Elixir.", dialectic: "Cares about cadence."},
      ...>   config
      ...> )
      iex> {stable, volatile} = LemonHoncho.Context.split(block)
      iex> {String.contains?(stable, "Writes Elixir."), volatile}
      {true, "Cares about cadence."}

      iex> LemonHoncho.Context.split("")
      {"", ""}
  """
  @spec split(String.t()) :: {String.t(), String.t()}
  def split(block) when is_binary(block) do
    case :binary.matches(block, @dialectic_marker) do
      [] ->
        {String.trim(block), ""}

      # The *first* occurrence, and the asymmetry is deliberate. The marker is
      # this module's own rendering, so ordinarily there is exactly one; a
      # second can only come from remote text that happens to contain the same
      # heading. Splitting too early puts stable text into the volatile half,
      # which costs a little cache coverage. Splitting too late puts the front
      # of the dialectic into the stable half — regenerated prose back inside
      # the cached prefix, which is the exact failure this split exists to
      # prevent, at full price on every turn. Erring early is the cheap error.
      [{start, length} | _rest] ->
        stable = block |> binary_part(0, start) |> String.trim() |> drop_preamble_only()

        volatile =
          block
          |> binary_part(start + length, byte_size(block) - start - length)
          |> String.trim()

        {stable, volatile}
    end
  end

  def split(_block), do: {"", ""}

  # A session whose only refreshed layer is the dialectic leaves a stable half
  # made of the heading and the preamble and nothing else — a label announcing
  # background, with no background under it. `assemble/2` already refuses to
  # render that shape from empty parts, for the reason its moduledoc gives: a
  # model will try to interpret the absence. Splitting is the one way to arrive
  # at it anyway, so it is refused here too. The framing is not lost with it —
  # the volatile half is placed by a caller that labels it where it lands.
  defp drop_preamble_only(stable) do
    if String.contains?(stable, "\n## "), do: stable, else: ""
  end

  @doc """
  Builds the natural-language question asked of Honcho's dialectic endpoint.

  There are two strategies, and which one is used is decided by
  `has_base_context?` — whether this session has ever produced a context block:

    * **Cold.** Nothing is known yet, so the question is general: who is this
      person, how do they work, what do they want. Asking a cold peer about the
      current message returns nothing useful, because there is no accumulated
      representation to select from.
    * **Warm.** Something is known, so the question is scoped to the session and
      to the message in hand: of everything you know, what matters *here*.

  The user's message is embedded in the warm query, truncated to
  #{@query_message_max_chars} characters at a word boundary. A blank message
  yields the warm question without a message section rather than falling back
  to the cold one — the session-scoped framing is still the right one.

  ## Examples

      iex> LemonHoncho.Context.dialectic_query("anything", false) =~ "Who is this person?"
      true

      iex> LemonHoncho.Context.dialectic_query("why is the build slow?", true) =~ "build slow"
      true
  """
  @spec dialectic_query(String.t() | nil, boolean()) :: String.t()
  def dialectic_query(_user_message, false), do: @cold_query

  def dialectic_query(user_message, true) do
    case clean(user_message) do
      "" ->
        @warm_query

      message ->
        @warm_query <>
          "\n\nTheir current message:\n" <> trim_to(message, @query_message_max_chars)
    end
  end

  ## Section building

  defp sections(parts, %Config{} = config) do
    [
      {"Session summary", clean(parts[:summary])},
      {"What is known about the user", clean(parts[:user_representation])},
      {"User profile", bullets(parts[:peer_card])},
      {"What is known about you", clean(parts[:ai_representation])},
      {@dialectic_title, dialectic(parts[:dialectic], config)}
    ]
    |> Enum.reject(fn {_title, body} -> body == "" end)
  end

  defp dialectic(value, %Config{} = config) do
    value |> clean() |> trim_to(config.dialectic_max_chars)
  end

  # Peer cards are short lines rather than prose, so they are rendered as a list
  # the model can scan. A card that arrives as one blob is split on newlines so
  # both shapes come out the same.
  #
  # Every clause here is total, on any term, and that is the point rather than
  # an accident. A card is remote JSON, so a list of it can hold maps, `null`s
  # or nested lists; `LemonHoncho.SessionManager` drops those where it first
  # accepts the field, but this runs inside that manager's own process and the
  # cost of being wrong about that is the manager dying with every session's
  # cached block. The per-entry `line/1` is what makes the list clause total —
  # the previous `to_string/1` raised `Protocol.UndefinedError` on a map.
  defp bullets(card) when is_binary(card) do
    card |> String.split("\n") |> bullets()
  end

  defp bullets(card) when is_list(card) do
    card
    |> Enum.map(&line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("\n", &("- " <> &1))
  end

  defp bullets(_card), do: ""

  # A number is rendered rather than dropped, because a card line that is just a
  # count or a year is still a fact about the user. Everything else a JSON list
  # can hold — a map, a nested list, `null`, a boolean — is dropped: `to_string/1`
  # either raises on it (maps) or invents a line nobody wrote (a nested list of
  # integers comes back as the characters at those codepoints).
  defp line(value) when is_number(value), do: to_string(value)
  defp line(value), do: clean(value)

  defp render([]), do: ""

  defp render(sections) do
    body = Enum.map_join(sections, "\n\n", fn {title, text} -> "## #{title}\n#{text}" end)

    @heading <> "\n\n" <> @preamble <> "\n\n" <> body
  end

  ## Budgeting

  defp budget("", _config), do: ""
  defp budget(text, %Config{context_tokens: nil}), do: text

  defp budget(text, %Config{context_tokens: tokens}) do
    trim_to(text, tokens * @chars_per_token)
  end

  # Cuts to `max` characters *including* the ellipsis, so the caller's budget is
  # a real ceiling rather than an approximate one, and backs up to the last
  # whitespace so the block never ends mid-word. A budget too small to hold even
  # the ellipsis yields "" rather than a lone ellipsis, which would read as
  # elided content that never existed.
  defp trim_to("", _max), do: ""

  defp trim_to(text, max) when is_integer(max) do
    ellipsis_length = String.length(@ellipsis)

    cond do
      String.length(text) <= max -> text
      max <= ellipsis_length -> ""
      true -> word_cut(text, max - ellipsis_length) <> @ellipsis
    end
  end

  # When the cut already lands on a boundary — the next character in the source
  # is whitespace, or there is no next character — the slice is kept whole.
  # Dropping the trailing word unconditionally would throw away a word that fit.
  defp word_cut(text, keep) do
    sliced = String.slice(text, 0, keep)

    if boundary?(String.slice(text, keep, 1)) do
      String.trim_trailing(sliced)
    else
      back_up_to_space(sliced)
    end
  end

  defp boundary?(""), do: true
  defp boundary?(character), do: String.match?(character, ~r/^\s$/u)

  defp back_up_to_space(sliced) do
    case Regex.run(~r/^(.*)\s\S*$/su, sliced, capture: :all_but_first) do
      [prefix] -> String.trim_trailing(prefix)
      nil -> String.trim_trailing(sliced)
    end
  end

  defp clean(nil), do: ""
  defp clean(value) when is_binary(value), do: String.trim(value)
  defp clean(_value), do: ""
end
