defmodule CodingAgent.Tools.Bash.ShellSegments do
  @moduledoc """
  Conservative simple-command scanner for bash preflight checks, not a shell evaluator.

  Preserves quoted argument text for regex rules, removes quotes for argv checks,
  and visits subshells and command substitutions without interpreting their output.
  Pipeline consumers retain their stdin context. Dynamic shell evaluation (aliases,
  functions, eval, variable expansion and heredocs) is intentionally not resolved.
  """

  @assignment ~r/\A[A-Za-z_][A-Za-z0-9_]*\+?=/
  @wrappers ~w(command builtin exec time nohup sudo env)
  @value_options ~w(-a -u -g -h -p -C -T --user --group --host --prompt --chdir --close-from --command-timeout)

  @doc "Returns simple commands with literal argv, original word text and pipe context."
  def extract(command) do
    {_rest, state} = scan(String.to_charlist(command), fresh(), nil)
    state |> finish() |> Enum.reverse() |> Enum.map(&unwrap/1)
  end

  defp fresh, do: %{word: [], raw: [], words: [], segments: [], quote: nil, piped: false}

  defp scan([], state, _stop), do: {[], state}
  defp scan([char | rest], %{quote: nil} = state, char), do: {rest, state}

  defp scan([?\\, ?\n | rest], %{quote: quote} = state, stop) when quote != :single,
    do: scan(rest, state, stop)

  defp scan([?\\, char | rest], %{quote: nil} = state, stop),
    do: scan(rest, append(state, [char], [char, ?\\]), stop)

  defp scan([?\\, char | rest], %{quote: :double} = state, stop)
       when char in [?", ?\\, ?$, ?`],
       do: scan(rest, append(state, [char], [char, ?\\]), stop)

  defp scan([?' | rest], %{quote: nil} = state, stop),
    do: scan(rest, %{append(state, [], [?']) | quote: :single}, stop)

  defp scan([?' | rest], %{quote: :single} = state, stop),
    do: scan(rest, %{append(state, [], [?']) | quote: nil}, stop)

  defp scan([?" | rest], %{quote: nil} = state, stop),
    do: scan(rest, %{append(state, [], [?"]) | quote: :double}, stop)

  defp scan([?" | rest], %{quote: :double} = state, stop),
    do: scan(rest, %{append(state, [], [?"]) | quote: nil}, stop)

  defp scan([?$, ?( | rest], %{quote: quote} = state, stop) when quote != :single,
    do: substitution(rest, state, stop, ?))

  defp scan([?` | rest], %{quote: quote} = state, stop) when quote != :single,
    do: substitution(rest, state, stop, ?`)

  defp scan([?( | rest], %{quote: nil} = state, stop) do
    {rest, child} = scan(rest, fresh(), ?))
    state = %{state | segments: finish(child) ++ finish(state), words: [], raw: [], word: []}
    scan(rest, state, stop)
  end

  defp scan([?# | rest], %{quote: nil, raw: []} = state, stop) do
    scan(Enum.drop_while(rest, &(&1 != ?\n)), state, stop)
  end

  defp scan([char | rest], %{quote: nil} = state, stop) when char in [?\s, ?\t, ?\r],
    do: scan(rest, push_word(state), stop)

  defp scan([char | rest], %{quote: nil} = state, stop) when char in [?;, ?\n, ?&, ?|, ?)] do
    {rest, pipe} = operator(char, rest)
    segments = finish(state)
    piped = if state.words == [] and state.raw == [] and char == ?\n, do: state.piped, else: pipe
    scan(rest, %{fresh() | segments: segments, piped: piped}, stop)
  end

  defp scan([char | rest], state, stop),
    do: scan(rest, append(state, [char], [char]), stop)

  defp substitution(rest, state, stop, close) do
    {rest, child} = scan(rest, fresh(), close)
    state = append(state, ~c"<substitution>", ~c"<substitution>")
    scan(rest, %{state | segments: finish(child) ++ state.segments}, stop)
  end

  defp operator(?|, [?| | rest]), do: {rest, false}
  defp operator(?|, [?& | rest]), do: {rest, true}
  defp operator(?|, rest), do: {rest, true}
  defp operator(?&, [?& | rest]), do: {rest, false}
  defp operator(_char, rest), do: {rest, false}

  defp append(state, word, raw),
    do: %{state | word: word ++ state.word, raw: raw ++ state.raw}

  defp push_word(%{raw: []} = state), do: state

  defp push_word(state) do
    word = %{
      value: state.word |> Enum.reverse() |> List.to_string(),
      raw: state.raw |> Enum.reverse() |> List.to_string()
    }

    %{state | words: [word | state.words], word: [], raw: []}
  end

  defp finish(state) do
    case push_word(state) do
      %{words: []} -> state.segments
      state -> [%{words: Enum.reverse(state.words), piped_stdin: state.piped} | state.segments]
    end
  end

  defp unwrap(segment) do
    words = strip_prefixes(segment.words)
    argv = Enum.map(words, & &1.value)

    text =
      case words do
        [] ->
          ""

        [program | args] ->
          Enum.join([Path.basename(program.value) | Enum.map(args, & &1.raw)], " ")
      end

    %{argv: argv, text: text, piped_stdin: segment.piped_stdin}
  end

  defp strip_prefixes([]), do: []

  defp strip_prefixes([word | rest] = words) do
    cond do
      Regex.match?(@assignment, word.value) ->
        strip_prefixes(rest)

      Path.basename(word.value) in @wrappers ->
        rest |> strip_options(Path.basename(word.value)) |> strip_prefixes()

      word.value in ["!", "if", "then", "else", "do"] ->
        strip_prefixes(rest)

      true ->
        words
    end
  end

  defp strip_options([%{value: "--"} | rest], _wrapper), do: rest

  defp strip_options([%{value: option}, _value | rest], wrapper)
       when option in @value_options and not (wrapper == "time" and option == "-p"),
       do: strip_options(rest, wrapper)

  defp strip_options([%{value: "-" <> _} | rest], wrapper), do: strip_options(rest, wrapper)
  defp strip_options(words, _wrapper), do: words
end
