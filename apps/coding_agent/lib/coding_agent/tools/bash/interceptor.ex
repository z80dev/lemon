defmodule CodingAgent.Tools.Bash.Interceptor do
  @moduledoc "Opt-in routing of file-oriented shell commands to available dedicated tools."

  alias CodingAgent.Tools.Bash.ShellSegments
  alias LemonCore.Config.Tools.Bash, as: BashConfig

  def check(command, opts) do
    config = Keyword.get(opts, :bash_config, %{})
    interceptor = get(config, :interceptor, %{})

    if get(interceptor, :enabled, false) do
      rules = get(interceptor, :rules, BashConfig.defaults()["interceptor"]["rules"])
      available = Keyword.get(opts, :available_tools, [])
      candidates = command |> ShellSegments.extract() |> Enum.reject(& &1.piped_stdin)
      match_rule(rules, available, candidates)
    else
      :ok
    end
  end

  defp match_rule(rules, available, candidates) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      tool = get(rule, :tool, nil)
      pattern = get(rule, :pattern, "")

      with true <- tool in available,
           {:ok, regex} <- Regex.compile(pattern),
           true <- Enum.any?(candidates, &Regex.match?(regex, &1.text)) do
        message =
          "Blocked: use the `#{tool}` tool. #{get(rule, :message, "")} " <>
            "Disable with [runtime.tools.bash.interceptor] enabled = false."

        {:halt, {:blocked, message}}
      else
        _ -> {:cont, :ok}
      end
    end)
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
