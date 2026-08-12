defmodule LemonHoncho.Egress do
  @moduledoc """
  The one place that decides what user-derived text may leave for Honcho.

  Honcho is a remote service, and three paths in this app carry text a human
  wrote to it: the session manager's retrieval query, the search tool's query,
  and the memory provider's recall query. All three end up as a URL query
  parameter on a `GET`, which means the text is not only stored by the far side
  but also written to its access log — a place nothing can be taken back from.

  Rather than let each of those paths invent its own rule, they all call
  `screen/2`. That is the point of this module: the policy is small enough to
  restate anywhere and important enough that a path which quietly forgot it
  would be invisible. One function, one policy, one place to change it.

  ## The policy

  Two steps, in this order:

    1. **Clip** to `max_chars`, counted in graphemes. `String.slice/3` counts
       graphemes, so a clipped emoji or a combining sequence is never split
       across the cut and no half-character reaches the wire.
    2. **Screen** the *clipped* text — the text that would actually be sent, not
       the original — with `LemonMemory.Safety.contains_secret?/1`, the same
       check `LemonMemory.Safety.safe_document?/1` runs over a summary before
       `LemonMemory.Ingest` will let it reach any provider.

  Clipping first is deliberate. The screen is applied to exactly the bytes that
  would travel, so a credential that survives the cut is caught and one that the
  cut removed does not cause a withhold that buys nothing.

  ## Withholding is whole, and silent about the text

  Text that trips the screen is dropped entirely rather than redacted in part:
  a partial redaction is a guess about where the secret ends, and the cost of
  guessing wrong is a credential in someone's log. `nil` is the withheld
  answer, and every caller already has to handle it, because a blank or
  non-binary input yields `nil` too.

  What each caller *does* with `nil` differs, and rightly so.
  `LemonHoncho.SessionManager` reads on without a query — there the query only
  focuses the representation, so losing it costs relevance and nothing else.
  `LemonHoncho.Tools.Search` refuses the call, because there the query *is* the
  request and a search of nothing reported as a search of something would be a
  wrong answer.

  The withhold is logged at debug and the log never contains the text. The whole
  reason it is being withheld is that it may be a credential, and a debug log is
  still somewhere it would persist.
  """

  require Logger

  alias LemonMemory.Safety

  @doc """
  Clips user-derived text to `max_chars` graphemes and withholds it if it looks
  like it carries a secret.

  Returns the clipped text, or `nil` meaning *do not send this at all*. `nil` is
  also the answer for blank text, for anything that is not a binary, and for a
  `max_chars` that is not a positive integer — this module errs toward sending
  nothing, since every caller has a working path for "no text" and none has one
  for "text that should not have left".

  ## Examples

      iex> LemonHoncho.Egress.screen("  why is the build slow?  ", 1_500)
      "why is the build slow?"

      iex> LemonHoncho.Egress.screen("abcdef", 3)
      "abc"

      iex> LemonHoncho.Egress.screen("my api_key: sk-live-4f9c1e2d8a7b6c5d0e9f8a7b", 1_500)
      nil

      iex> LemonHoncho.Egress.screen("   ", 1_500)
      nil

      iex> LemonHoncho.Egress.screen(nil, 1_500)
      nil
  """
  @spec screen(term(), pos_integer()) :: String.t() | nil
  def screen(text, max_chars)
      when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    case String.trim(text) do
      "" -> nil
      trimmed -> withhold_secrets(String.slice(trimmed, 0, max_chars))
    end
  end

  def screen(_text, _max_chars), do: nil

  defp withhold_secrets(text) do
    if Safety.contains_secret?(text) do
      Logger.debug("honcho: text withheld from egress, it looks like it carries a secret")
      nil
    else
      text
    end
  end
end
