defmodule CodingAgent.Tools.Bash.CommandPolicy do
  @moduledoc """
  Enforces a tool policy's `allowed_commands` and `blocked_commands` on shell
  text before anything is spawned.

  This is a best-effort string check over `ShellSegments`, not a sandbox: the
  shell can still build a command at run time (variable expansion, `eval`,
  aliases, scripts on disk, an interpreter reading its program from stdin), so
  a list cannot contain a determined caller. It never fails open on what it can
  see:

    * `blocked_commands` matches broadly. An entry such as `"rm -rf"` blocks
      any segment where a word whose basename is `rm` is followed, in order, by
      the word `-rf`, wherever the segment starts (so `sudo rm -rf`, `/bin/rm
      -rf` and `echo rm -rf` all match). Quoted words that contain whitespace
      are scanned again as shell text, which catches `bash -c '...'`.
    * `allowed_commands` matches narrowly. Every segment, including those in
      subshells and command substitutions, must begin with an entry's words
      exactly (no path, assignment or wrapper prefix), and no word may contain
      a redirection or substitution (`<`, `>`). An empty list allows nothing.

  `eval` and `debug` run arbitrary code that no command list can inspect, so
  `restricted?/1` lets them refuse whenever a list is set.
  """

  alias CodingAgent.Tools.Bash.ShellSegments
  alias LemonCore.ToolPolicy

  @max_depth 4

  @doc "True when the policy sets either command list (or cannot be read)."
  @spec restricted?(term()) :: boolean()
  def restricted?(policy) do
    case normalize(policy) do
      nil -> false
      %ToolPolicy{allowed_commands: :all, blocked_commands: []} -> false
      _restricted -> true
    end
  end

  @doc """
  Checks shell text against both lists. Returns `:ok` or `{:blocked, message}`.
  A `nil` policy is the unrestricted baseline; an unreadable one refuses.
  """
  @spec check(String.t(), term()) :: :ok | {:blocked, String.t()}
  def check(command, policy) when is_binary(command) do
    case normalize(policy) do
      :invalid ->
        {:blocked, "Command refused: the tool policy is invalid."}

      policy ->
        with :ok <- check_blocked(command, policy), do: check_allowed(command, policy)
    end
  end

  @doc "Checks text against `blocked_commands` only (used for process input)."
  @spec check_blocked(String.t(), term()) :: :ok | {:blocked, String.t()}
  def check_blocked(command, policy) when is_binary(command) do
    case normalize(policy) do
      :invalid ->
        {:blocked, "Input refused: the tool policy is invalid."}

      %ToolPolicy{blocked_commands: [_ | _] = blocked} ->
        words = command |> String.replace_invalid() |> segments(0) |> Enum.map(&words/1)

        case Enum.find(blocked, fn entry ->
               Enum.any?(words, &blocked_match?(&1, tokens(entry)))
             end) do
          nil ->
            :ok

          entry ->
            {:blocked,
             "Command refused by tool policy: it matches blocked_commands entry " <>
               "#{inspect(entry)}."}
        end

      _unblocked ->
        :ok
    end
  end

  defp normalize(nil), do: nil

  defp normalize(policy) do
    case ToolPolicy.parse(policy) do
      {:ok, policy} -> policy
      {:error, _} -> :invalid
    end
  end

  @doc """
  Refuses a call-level environment under `allowed_commands`: `PATH`, `BASH_ENV`
  and similar variables would change what an allowed command name runs.
  """
  @spec check_env(map() | nil, term()) :: :ok | {:blocked, String.t()}
  def check_env(env, _policy) when env in [nil, %{}], do: :ok

  def check_env(_env, policy) do
    case normalize(policy) do
      %ToolPolicy{allowed_commands: :all} ->
        :ok

      nil ->
        :ok

      _restricted ->
        {:blocked, "env is refused by tool policy while allowed_commands is set."}
    end
  end

  @doc "Refusal message for tools that cannot run under command lists."
  @spec unavailable(String.t()) :: String.t()
  def unavailable(tool) do
    "#{tool} is unavailable under this tool policy: allowed_commands/blocked_commands are set " <>
      "and #{tool} runs code no command list can inspect."
  end

  defp check_allowed(_command, nil), do: :ok
  defp check_allowed(_command, %ToolPolicy{allowed_commands: :all}), do: :ok

  defp check_allowed(command, %ToolPolicy{allowed_commands: allowed}) do
    segments = ShellSegments.extract(command)
    entries = Enum.map(allowed, &tokens/1)

    refused =
      segments == [] or
        Enum.any?(segments, fn segment ->
          Enum.any?(segment.words, &String.match?(&1.raw, ~r/[<>]/)) or
            not Enum.any?(entries, &List.starts_with?(words(segment), &1))
        end)

    if refused do
      {:blocked,
       "Command refused by tool policy: every command must start with an allowed_commands " <>
         "entry (#{if allowed == [], do: "none allowed", else: Enum.join(allowed, ", ")}), " <>
         "without path, variable or wrapper prefixes and without redirection."}
    else
      :ok
    end
  end

  # Segments of the command plus, for any word containing whitespace (a quoted
  # string that may be a nested script), the segments of that word's text.
  defp segments(_command, depth) when depth > @max_depth, do: []

  defp segments(command, depth) do
    found = ShellSegments.extract(command)

    nested =
      for segment <- found,
          %{value: value} <- segment.words,
          String.match?(value, ~r/\s/),
          nested <- segments(value, depth + 1),
          do: nested

    found ++ nested
  end

  defp words(segment), do: Enum.map(segment.words, & &1.value)

  defp tokens(entry), do: String.split(entry)

  defp blocked_match?(_words, []), do: false

  defp blocked_match?(words, [program | rest]) do
    words
    |> Enum.with_index()
    |> Enum.any?(fn {word, index} ->
      Path.basename(word) == program and
        subsequence?(rest, Enum.drop(words, index + 1))
    end)
  end

  defp subsequence?([], _words), do: true
  defp subsequence?(_needle, []), do: false
  defp subsequence?([n | ns], [n | ws]), do: subsequence?(ns, ws)
  defp subsequence?(needle, [_ | ws]), do: subsequence?(needle, ws)
end
