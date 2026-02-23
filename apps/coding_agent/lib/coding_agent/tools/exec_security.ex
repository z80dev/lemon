defmodule CodingAgent.Tools.ExecSecurity do
  @moduledoc """
  Security detection for obfuscated shell commands.

  Detects common obfuscation techniques used to bypass allowlist filters,
  such as backtick substitution, variable expansion, command substitution,
  base64 encoding tricks, and empty-string concatenation.

  These patterns are dangerous because they can be used to execute commands
  that would otherwise be blocked by an exec approval/allowlist system.
  """

  @type detection_result :: :ok | {:obfuscated, String.t()}

  @doc """
  Checks a command string for known obfuscation patterns.

  Returns `:ok` if no obfuscation is detected, or `{:obfuscated, technique}`
  describing the detected obfuscation technique if one is found.

  ## Examples

      iex> ExecSecurity.check("ls -la")
      :ok

      iex> ExecSecurity.check("`cat /etc/passwd`")
      {:obfuscated, "backtick substitution (`...`)"}

      iex> ExecSecurity.check("$(cat /etc/passwd)")
      {:obfuscated, "command substitution ($(..))"}

      iex> ExecSecurity.check("echo ${HOME}")
      {:obfuscated, "variable substitution (${VAR})"}

      iex> ExecSecurity.check("echo $HOME")
      {:obfuscated, "variable substitution ($VAR)"}

      iex> ExecSecurity.check("c''a''t /etc/passwd")
      {:obfuscated, "string concatenation (x''y)"}

      iex> ExecSecurity.check("c\"\"a\"\"t /etc/passwd")
      {:obfuscated, "string concatenation (x\\\"\\\"y)"}
  """
  @spec check(String.t()) :: detection_result()
  def check(command) when is_binary(command) do
    detectors = [
      &detect_backtick_substitution/1,
      &detect_command_substitution/1,
      &detect_variable_braced/1,
      &detect_variable_simple/1,
      &detect_string_concatenation_single/1,
      &detect_string_concatenation_double/1
    ]

    Enum.reduce_while(detectors, :ok, fn detector, :ok ->
      case detector.(command) do
        :ok -> {:cont, :ok}
        {:obfuscated, _} = result -> {:halt, result}
      end
    end)
  end

  @doc """
  Returns a human-readable rejection message for the detected obfuscation technique.

  ## Examples

      iex> ExecSecurity.rejection_message("backtick substitution (`...`)")
      "Command rejected: obfuscation detected (backtick substitution (`...`)). ..."
  """
  @spec rejection_message(String.t()) :: String.t()
  def rejection_message(technique) do
    "Command rejected: obfuscation detected (#{technique}). " <>
      "Shell obfuscation techniques may be used to bypass command filters. " <>
      "Please use explicit, unobfuscated commands."
  end

  # ---------------------------------------------------------------------------
  # Private detectors
  # ---------------------------------------------------------------------------

  # Backtick command substitution: `command`
  defp detect_backtick_substitution(command) do
    if Regex.match?(~r/`[^`]+`/, command) do
      {:obfuscated, "backtick substitution (`...`)"}
    else
      :ok
    end
  end

  # $(...) command substitution, also covers $(echo ... | base64 -d) encoding tricks
  defp detect_command_substitution(command) do
    if Regex.match?(~r/\$\(/, command) do
      {:obfuscated, "command substitution ($(..))"}
    else
      :ok
    end
  end

  # ${VAR} braced variable substitution
  defp detect_variable_braced(command) do
    if Regex.match?(~r/\$\{[^}]+\}/, command) do
      {:obfuscated, "variable substitution (${VAR})"}
    else
      :ok
    end
  end

  # $VAR simple variable substitution (excludes $( and ${ already handled above)
  defp detect_variable_simple(command) do
    if Regex.match?(~r/\$[A-Za-z_][A-Za-z0-9_]*/, command) do
      {:obfuscated, "variable substitution ($VAR)"}
    else
      :ok
    end
  end

  # Empty single-quote concatenation: c''a''t splits a command name to bypass filters
  defp detect_string_concatenation_single(command) do
    if Regex.match?(~r/[A-Za-z]''[A-Za-z]/, command) do
      {:obfuscated, "string concatenation (x''y)"}
    else
      :ok
    end
  end

  # Empty double-quote concatenation: c""a""t
  defp detect_string_concatenation_double(command) do
    if Regex.match?(~r/[A-Za-z]""[A-Za-z]/, command) do
      {:obfuscated, ~s{string concatenation (x""y)}}
    else
      :ok
    end
  end
end
