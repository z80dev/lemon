defmodule CodingAgent.Security.SecretObfuscator.Loader do
  @moduledoc false
  # Secret sources: secret-shaped environment variables, `secrets.yml` (global
  # `<agent_dir>/secrets.yml` and project `<cwd>/.lemon/secrets.yml`) and the
  # built-in credential-token regex.

  require Logger

  alias CodingAgent.Security.SecretObfuscator.{Placeholder, Replacement}

  @type entry :: %{
          required(:type) => :plain | :regex,
          required(:content) => String.t(),
          required(:mode) => :obfuscate | :replace,
          optional(:replacement) => String.t() | nil,
          optional(:flags) => String.t() | nil,
          optional(:friendly_name) => String.t() | nil
        }

  @min_env_value_length 8
  @secret_env_name ~r/(?:KEY|SECRET|TOKEN|PASSWORD|PASS|AUTH|CREDENTIAL|PRIVATE|OAUTH)(?:_|$)/i

  # GitHub, GitLab, OpenAI and Anthropic-style credential tokens (omp's
  # SENSITIVE_TOKEN_RE), matched case-insensitively.
  @builtin_token_source "(?<![a-zA-Z0-9_*-])(gh[opusr]_[a-zA-Z0-9_*]{36,}|github_pat_[a-zA-Z0-9_*]{36,}|glpat-[a-zA-Z0-9_*-]{20,}|sk-proj-[a-zA-Z0-9_*-]{36,}|sk-ant-[a-zA-Z0-9_*-]{36,}|sk-[a-zA-Z0-9_*-]{48,})(?![a-zA-Z0-9_*-])"

  @literal_re ~r/^\/((?:[^\\\/]|\\.)*)\/([ gimsuy]*)$/s

  @doc "Plain obfuscate entries for secret-shaped environment variables."
  @spec env_entries(%{optional(String.t()) => String.t()}) :: [entry()]
  def env_entries(env) when is_map(env) do
    env
    |> Enum.sort()
    |> Enum.filter(fn {name, value} ->
      is_binary(value) and Replacement.text_length(value) >= @min_env_value_length and
        Regex.match?(@secret_env_name, name)
    end)
    |> Enum.map(fn {_name, value} -> value end)
    |> Enum.uniq()
    |> Enum.map(&%{type: :plain, content: &1, mode: :obfuscate})
  end

  @doc "Built-in reversible entry for credential-shaped tokens."
  @spec builtin_entries() :: [entry()]
  def builtin_entries do
    [
      %{
        type: :regex,
        content: @builtin_token_source,
        flags: "i",
        mode: :obfuscate,
        friendly_name: "Credential"
      }
    ]
  end

  @doc """
  Load `secrets.yml` entries; project entries override global entries with the
  same `content`.
  """
  @spec file_entries(Path.t(), Path.t()) :: [entry()]
  def file_entries(cwd, agent_dir) do
    global = load_file(Path.join(agent_dir, "secrets.yml"))
    project = load_file(Path.join([cwd, ".lemon", "secrets.yml"]))
    project_contents = MapSet.new(project, & &1.content)
    Enum.reject(global, &MapSet.member?(project_contents, &1.content)) ++ project
  end

  @doc """
  Compile a secret regex. Accepts `/pattern/flags` literal syntax; JavaScript
  flags `i`, `m`, `s`, `u` map to PCRE options and `g`/`y` are implied.
  """
  @spec compile_regex(String.t(), String.t() | nil) :: {:ok, Regex.t()} | {:error, term()}
  def compile_regex(pattern, flags \\ nil) do
    {pattern, flags} =
      case Regex.run(@literal_re, pattern, capture: :all_but_first) do
        [literal_pattern, literal_flags] -> {literal_pattern, (flags || "") <> literal_flags}
        _ -> {pattern, flags || ""}
      end

    with {:ok, options} <- regex_options(flags) do
      Regex.compile(pattern, options)
    end
  end

  defp regex_options(flags) do
    flags
    |> String.graphemes()
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn
      "i", {:ok, acc} -> {:cont, {:ok, [:caseless | acc]}}
      "m", {:ok, acc} -> {:cont, {:ok, [:multiline | acc]}}
      "s", {:ok, acc} -> {:cont, {:ok, [:dotall | acc]}}
      "u", {:ok, acc} -> {:cont, {:ok, [:unicode | acc]}}
      flag, acc when flag in ["g", "y", "d", " "] -> {:cont, acc}
      flag, _acc -> {:halt, {:error, {:invalid_flag, flag}}}
    end)
    |> case do
      {:ok, options} ->
        # JavaScript `$` without `m` only matches at the very end of input.
        if :multiline in options, do: {:ok, options}, else: {:ok, [:dollar_endonly | options]}

      error ->
        error
    end
  end

  defp load_file(path) do
    case File.read(path) do
      {:ok, text} -> parse_file(text, path)
      {:error, :enoent} -> []
      {:error, reason} -> warn(path, "could not be read: #{inspect(reason)}")
    end
  end

  defp parse_file(text, path) do
    case YamlElixir.read_from_string(text) do
      {:ok, entries} when is_list(entries) ->
        entries
        |> Enum.with_index()
        |> Enum.flat_map(fn {entry, index} ->
          case validate(entry) do
            {:ok, entry} ->
              {raw_name, entry} = Map.pop(entry, :raw_friendly_name)
              [Map.put(entry, :friendly_name, friendly_name(raw_name, path, index))]

            {:error, message} ->
              warn(path, "[#{index}]: #{message}")
          end
        end)

      # An empty file parses to nil/empty and means no entries.
      {:ok, empty} when empty in [nil, ""] ->
        []

      {:ok, _other} ->
        warn(path, "must be a YAML array")

      {:error, _reason} ->
        warn(path, "could not be parsed")
    end
  end

  defp validate(entry) when is_map(entry) do
    with {:ok, type} <- validate_type(entry["type"]),
         :ok <- validate_content(entry["content"]),
         {:ok, mode} <- validate_mode(entry["mode"]),
         :ok <- optional_string(entry, "replacement"),
         :ok <- optional_string(entry, "flags"),
         :ok <- validate_regex(type, mode, entry) do
      {:ok,
       %{
         type: type,
         content: entry["content"],
         mode: mode,
         replacement: entry["replacement"],
         flags: entry["flags"],
         raw_friendly_name: entry["friendlyName"]
       }}
    end
  end

  defp validate(_entry), do: {:error, "entry must be an object"}

  defp validate_type("plain"), do: {:ok, :plain}
  defp validate_type("regex"), do: {:ok, :regex}
  defp validate_type(_), do: {:error, ~s(type must be "plain" or "regex")}

  defp validate_content(content) when is_binary(content) and content != "", do: :ok
  defp validate_content(_), do: {:error, "content must be a non-empty string"}

  defp validate_mode(nil), do: {:ok, :obfuscate}
  defp validate_mode("obfuscate"), do: {:ok, :obfuscate}
  defp validate_mode("replace"), do: {:ok, :replace}
  defp validate_mode(_), do: {:error, ~s(mode must be "obfuscate" or "replace")}

  defp optional_string(entry, key) do
    case entry[key] do
      nil -> :ok
      value when is_binary(value) -> :ok
      _ -> {:error, "#{key} must be a string"}
    end
  end

  defp validate_regex(:plain, _mode, _entry), do: :ok

  defp validate_regex(:regex, mode, entry) do
    case compile_regex(entry["content"], entry["flags"]) do
      {:ok, regex} ->
        if mode == :replace and is_nil(entry["replacement"]) and
             Replacement.unresolvable_short_match?(regex) do
          {:error,
           "regex matches every 1-2 character candidate with no custom replacement, " <>
             "so a match can never be redacted distinctly from itself"}
        else
          :ok
        end

      {:error, reason} ->
        {:error, "invalid regex pattern: #{inspect(reason)}"}
    end
  end

  # Invalid optional friendlyName metadata is dropped without dropping the entry.
  # The label is kept unsanitized: the obfuscator checks the raw label against
  # configured regexes before sanitizing it into a placeholder prefix.
  defp friendly_name(nil, _path, _index), do: nil

  defp friendly_name(name, path, index) when is_binary(name) do
    if Placeholder.sanitize_friendly_name(name) do
      name
    else
      warn(path, "[#{index}]: friendlyName must contain at least one letter or digit")
      nil
    end
  end

  defp friendly_name(_name, path, index) do
    warn(path, "[#{index}]: friendlyName must be a string")
    nil
  end

  # Logs and yields no entries.
  defp warn(path, message) do
    Logger.warning("secrets.yml #{path} #{message}")
    []
  end
end
