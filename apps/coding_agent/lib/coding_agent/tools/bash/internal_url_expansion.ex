defmodule CodingAgent.Tools.Bash.InternalUrlExpansion do
  @moduledoc """
  Replaces `skill://` and `artifact://` references in a bash command with the
  shell-quoted absolute paths they resolve to, so shell programs can read them.

  A reference is a whole shell word: bare (`cat artifact://<id>`) or wrapped in
  matching quotes (`cat "skill://key/notes.md"`). Bare references stop before
  shell syntax (`;`, `|`, `&`, `<`, `>`, `(`, `$`, quotes, backticks) so an
  adjacent operator is never quoted into the path. Only these two schemes are
  recognised, and only at a word start, so `https://`, `git://` or
  `myskill://` are untouched. Mentions inside larger quoted text (for example
  a commit message) are left as written.

  Resolution goes through `CodingAgent.InternalUrls.resolve/2`; any reference
  that cannot be resolved fails the whole expansion so the command never runs
  with a dangling URL.
  """

  alias CodingAgent.InternalUrls

  @pattern ~r{(?<![\w.+\-/:])(?:'(?:skill|artifact|local)://[^'\s")`\\]+'|"(?:skill|artifact|local)://[^"\s')`\\]+"|(?:skill|artifact|local)://[^\s'")`\\;&|<>($]+)}

  @doc """
  Expands internal URL references in `command`.

  `opts` must include `:cwd` (the session working directory) and the session
  options (`:session_id`, optional `:context_guardrails`) used to locate the
  session's artifact index.
  """
  @spec expand(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def expand(command, opts) when is_binary(command) do
    if String.contains?(command, "://") do
      @pattern
      |> Regex.scan(command, return: :index)
      |> Enum.reject(fn [{start, length}] ->
        embedded_in_quoted_text?(command, binary_part(command, start, length), start)
      end)
      |> Enum.reduce_while({:ok, []}, fn [{start, length}], {:ok, acc} ->
        url = command |> binary_part(start, length) |> unquote_token()

        case InternalUrls.resolve(url, opts) do
          {:ok, path} ->
            {:cont, {:ok, [{start, length, shell_quote(path)} | acc]}}

          {:error, reason} ->
            {:halt,
             {:error,
              "Cannot resolve #{url} in the bash command (#{describe(reason)}); " <>
                "the command was not run."}}
        end
      end)
      |> case do
        {:ok, replacements} -> {:ok, splice(command, replacements)}
        error -> error
      end
    else
      {:ok, command}
    end
  end

  # Replacements arrive last-first, so earlier byte offsets stay valid.
  defp splice(command, replacements) do
    Enum.reduce(replacements, command, fn {start, length, replacement}, acc ->
      tail_start = start + length

      binary_part(acc, 0, start) <>
        replacement <> binary_part(acc, tail_start, byte_size(acc) - tail_start)
    end)
  end

  defp unquote_token(<<quote, rest::binary>> = token) when quote in [?', ?"] do
    if String.ends_with?(rest, <<quote>>),
      do: binary_part(rest, 0, byte_size(rest) - 1),
      else: token
  end

  defp unquote_token(token), do: token

  defp shell_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(:unknown_protocol), do: "unknown protocol"
  defp describe(reason), do: inspect(reason)

  defp embedded_in_quoted_text?(_command, <<quote, _::binary>>, _start) when quote in [?', ?"],
    do: false

  defp embedded_in_quoted_text?(command, _token, start),
    do: command |> binary_part(0, start) |> inside_quote?(nil, [])

  # Tracks shell quoting up to a byte offset. Command substitutions reset the
  # quote context and restore the enclosing one when they close. Inside a
  # backtick substitution nested in double quotes, `\"` delimits inner quotes.
  defp inside_quote?(<<>>, quote, _subs), do: quote != nil

  defp inside_quote?(<<?\\, ?", rest::binary>>, quote, [{:backtick, ?", _} | _] = subs)
       when quote != ?',
       do: inside_quote?(rest, toggle(quote, ?"), subs)

  defp inside_quote?(<<?\\, _escaped, rest::binary>>, quote, subs) when quote != ?',
    do: inside_quote?(rest, quote, subs)

  defp inside_quote?(<<?', rest::binary>>, quote, subs) when quote != ?",
    do: inside_quote?(rest, toggle(quote, ?'), subs)

  defp inside_quote?(<<?", rest::binary>>, quote, subs) when quote != ?',
    do: inside_quote?(rest, toggle(quote, ?"), subs)

  defp inside_quote?(<<?$, ?(, rest::binary>>, quote, subs) when quote != ?',
    do: inside_quote?(rest, nil, [{:dollar, quote, 1} | subs])

  defp inside_quote?(<<?`, rest::binary>>, quote, subs) when quote != ?' do
    case subs do
      [{:backtick, outer, _} | outer_subs] -> inside_quote?(rest, outer, outer_subs)
      _ -> inside_quote?(rest, nil, [{:backtick, quote, 0} | subs])
    end
  end

  defp inside_quote?(<<_byte, rest::binary>>, quote, subs) when quote != nil,
    do: inside_quote?(rest, quote, subs)

  defp inside_quote?(<<?(, rest::binary>>, nil, [{:dollar, outer, depth} | outer_subs]),
    do: inside_quote?(rest, nil, [{:dollar, outer, depth + 1} | outer_subs])

  defp inside_quote?(<<?), rest::binary>>, nil, [{:dollar, outer, 1} | outer_subs]),
    do: inside_quote?(rest, outer, outer_subs)

  defp inside_quote?(<<?), rest::binary>>, nil, [{:dollar, outer, depth} | outer_subs]),
    do: inside_quote?(rest, nil, [{:dollar, outer, depth - 1} | outer_subs])

  defp inside_quote?(<<_byte, rest::binary>>, quote, subs), do: inside_quote?(rest, quote, subs)

  defp toggle(quote, quote), do: nil
  defp toggle(_current, quote), do: quote
end
