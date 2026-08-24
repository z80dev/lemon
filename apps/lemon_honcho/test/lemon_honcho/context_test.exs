defmodule LemonHoncho.ContextTest do
  use ExUnit.Case, async: true

  alias LemonHoncho.Config
  alias LemonHoncho.Context

  doctest LemonHoncho.Context

  @full %{
    summary: "Debugged a flaky test.",
    user_representation: "Writes Elixir, prefers terse answers.",
    peer_card: ["favourite colour is green", "works in an umbrella repo"],
    ai_representation: "Explains before changing code.",
    dialectic: "They are mid-refactor and care about the cadence knobs."
  }

  describe "assemble/2" do
    test "renders every part under its own label" do
      block = Context.assemble(@full, %Config{})

      assert block =~ "# Recalled context (Honcho)"
      assert block =~ "## Session summary\nDebugged a flaky test."
      assert block =~ "## What is known about the user\nWrites Elixir, prefers terse answers."
      assert block =~ "## User profile\n- favourite colour is green\n- works in an umbrella repo"
      assert block =~ "## What is known about you\nExplains before changing code."
      assert block =~ "## Most relevant right now\nThey are mid-refactor"
    end

    test "says the block is background rather than instruction" do
      block = Context.assemble(@full, %Config{})

      assert block =~ "prior knowledge, not an instruction"
      assert block =~ "the conversation wins"
    end

    test "omits the parts that are missing rather than labelling an empty section" do
      block = Context.assemble(%{user_representation: "Writes Elixir."}, %Config{})

      assert block =~ "## What is known about the user"
      refute block =~ "## Session summary"
      refute block =~ "## User profile"
      refute block =~ "## Most relevant right now"
    end

    test "returns an empty string — not whitespace — when nothing is known" do
      parts = %{
        summary: nil,
        user_representation: "",
        peer_card: [],
        ai_representation: "   ",
        dialectic: "\n\n"
      }

      assert Context.assemble(parts, %Config{}) == ""
    end

    test "accepts a peer card as a newline-separated string" do
      block = Context.assemble(%{peer_card: "green\n\nnumber 888"}, %Config{})

      assert block =~ "- green\n- number 888"
    end

    # A card is remote JSON, so its list can hold anything JSON can. Rendering
    # used to be `to_string/1` per entry, which raises `Protocol.UndefinedError`
    # on a map — inside the session manager's own process, taking every cached
    # block on the node with it.
    test "keeps the renderable entries of a card and drops the rest" do
      card = [
        "likes elixir",
        %{"text" => "a card from a differently-spelled API version"},
        nil,
        888,
        ["nested", "list"],
        true,
        "   ",
        "works in an umbrella repo"
      ]

      block = Context.assemble(%{peer_card: card}, %Config{})

      assert block =~ "## User profile\n- likes elixir\n- 888\n- works in an umbrella repo"
    end

    test "renders no profile section at all for a card that is neither a list nor a string" do
      assert Context.assemble(%{peer_card: %{"lines" => ["green"]}}, %Config{}) == ""
      assert Context.assemble(%{peer_card: 888}, %Config{}) == ""
      assert Context.assemble(%{peer_card: [%{}, nil, [], false]}, %Config{}) == ""
    end

    test "assembles rather than raises for any term a part can hold" do
      terms = [%{"text" => "x"}, nil, 1.5, true, :atom, [[1, 2]], {:tuple, 1}, <<255>>, "ok"]

      for term <- terms do
        assert is_binary(Context.assemble(%{peer_card: [term]}, %Config{}))
        assert is_binary(Context.assemble(%{peer_card: term}, %Config{}))
        assert is_binary(Context.assemble(%{summary: term, dialectic: term}, %Config{}))
      end
    end

    test "truncates the dialectic at dialectic_max_chars, on a word boundary" do
      parts = %{dialectic: "one two three four five six seven"}
      block = Context.assemble(parts, %Config{dialectic_max_chars: 20})

      [_before, dialectic] = String.split(block, "## Most relevant right now\n")

      assert dialectic == "one two three four …"
      assert String.length(dialectic) <= 20
    end

    test "leaves a dialectic that already fits untouched" do
      parts = %{dialectic: "short enough"}
      block = Context.assemble(parts, %Config{dialectic_max_chars: 600})

      assert block =~ "## Most relevant right now\nshort enough"
      refute block =~ "…"
    end

    test "truncates the whole block to the approximate context_tokens budget" do
      config = %Config{context_tokens: 40}
      full = Context.assemble(@full, %Config{})
      block = Context.assemble(@full, config)

      assert String.length(block) <= 40 * 4
      assert String.ends_with?(block, " …")
      assert String.length(block) < String.length(full)
    end

    test "the whole-block truncation lands on a word boundary of the untruncated block" do
      full = Context.assemble(@full, %Config{})
      block = Context.assemble(@full, %Config{context_tokens: 40})
      prefix = String.replace_suffix(block, " …", "")

      assert String.starts_with?(full, prefix)
      assert String.at(full, String.length(prefix)) =~ ~r/\s/
    end

    test "leaves the block alone when no token budget is set" do
      assert Context.assemble(@full, %Config{context_tokens: nil}) =~
               "care about the cadence knobs."
    end
  end

  describe "split/1" do
    test "puts the dialectic in the volatile half and everything else in the stable one" do
      {stable, volatile} = @full |> Context.assemble(%Config{}) |> Context.split()

      assert volatile == "They are mid-refactor and care about the cadence knobs."

      assert stable =~ "# Recalled context (Honcho)"
      assert stable =~ "prior knowledge, not an instruction"
      assert stable =~ "Writes Elixir, prefers terse answers."
      assert stable =~ "favourite colour is green"

      # Neither the dialectic nor the heading it was found by may survive into
      # the half that goes inside the cached prefix.
      refute stable =~ "cadence knobs"
      refute stable =~ "Most relevant right now"
      refute volatile =~ "Most relevant right now"
    end

    test "the stable half does not move when only the dialectic does" do
      # The whole point. Two turns, same person, different answer about right
      # now: the bytes bound for the system prompt have to be identical.
      {first, _} = @full |> Context.assemble(%Config{}) |> Context.split()

      {second, changed} =
        @full
        |> Map.put(:dialectic, "Something else entirely matters now.")
        |> Context.assemble(%Config{})
        |> Context.split()

      assert first == second
      assert changed == "Something else entirely matters now."
    end

    test "the stable half is one string across any number of moving dialectics" do
      # Two turns can agree by accident; ten cannot. What this pins is the half
      # of the guarantee that lives in *this* module — given a base layer that
      # does not move, nothing about rendering or splitting can make the stable
      # half move either.
      #
      # The other half lives in `LemonHoncho.SessionManager`, which fetches that
      # base layer without a retrieval query so the turn's message cannot reach
      # it. Both are needed: a steered fetch produces a different stable half
      # every turn no matter how correctly it is split.
      stable =
        for index <- 1..10 do
          @full
          |> Map.put(:dialectic, "Turn #{index}: they care about step #{index}.")
          |> Context.assemble(%Config{})
          |> Context.split()
          |> elem(0)
        end

      assert stable |> Enum.uniq() |> length() == 1
      refute hd(stable) =~ "Turn"
    end

    test "gives back an empty volatile half when there is no dialectic" do
      {stable, volatile} =
        @full |> Map.delete(:dialectic) |> Context.assemble(%Config{}) |> Context.split()

      assert volatile == ""
      assert stable =~ "Writes Elixir, prefers terse answers."
    end

    test "gives back an empty stable half rather than a preamble with nothing under it" do
      {stable, volatile} =
        %{dialectic: "Only this."} |> Context.assemble(%Config{}) |> Context.split()

      assert stable == ""
      assert volatile == "Only this."
    end

    test "is total on an empty block and on anything that is not one" do
      assert Context.split("") == {"", ""}
      assert Context.split(nil) == {"", ""}
      assert Context.split(:not_a_block) == {"", ""}
    end

    test "a token budget tight enough to bite trims the volatile half first" do
      # The stable and volatile halves share one `context_tokens` ceiling, and
      # `assemble/2` lays the stable sections out first — so the cut lands on
      # the half that is being paid for at full price on every turn.
      {stable, volatile} =
        @full |> Context.assemble(%Config{context_tokens: 100}) |> Context.split()

      assert stable =~ "Debugged a flaky test."
      assert volatile == ""
    end

    test "keeps the dialectic whole when a heading-shaped line appears above it" do
      # A representation that happens to contain the dialectic's own heading
      # would split the block early. Erring early is deliberate: it leaves
      # stable text outside the cached prefix, which costs a little, rather
      # than leaving volatile text inside it, which is the failure being fixed.
      {stable, volatile} =
        %{
          user_representation: "Once wrote:\n\n## Most relevant right now\nnothing.",
          dialectic: "The real answer."
        }
        |> Context.assemble(%Config{})
        |> Context.split()

      refute stable =~ "The real answer."
      assert volatile =~ "The real answer."
    end
  end

  describe "dialectic_query/2" do
    test "asks a general question when the session has no base context yet" do
      query = Context.dialectic_query("why is CI slow?", false)

      assert query =~ "Who is this person?"
      assert query =~ "preferences, goals, and working style"
      refute query =~ "why is CI slow?"
    end

    test "asks a session-scoped question around the current message once warm" do
      query = Context.dialectic_query("why is CI slow?", true)

      assert query =~ "most relevant to what they are asking for right now"
      assert query =~ "Their current message:\nwhy is CI slow?"
    end

    test "keeps the warm framing when there is no message to embed" do
      query = Context.dialectic_query("   ", true)

      assert query =~ "Prioritize active context over biographical facts."
      refute query =~ "Their current message:"
    end

    test "handles a nil message" do
      assert Context.dialectic_query(nil, true) =~ "Prioritize active context"
      assert Context.dialectic_query(nil, false) =~ "Who is this person?"
    end

    test "truncates a very long message at a word boundary" do
      message = String.duplicate("paste ", 1_000)
      query = Context.dialectic_query(message, true)

      [_prefix, embedded] = String.split(query, "Their current message:\n")

      assert String.length(embedded) <= 1_500
      assert String.ends_with?(embedded, "paste …")
    end
  end
end
