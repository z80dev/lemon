defmodule LemonCore.Config.Tools.Bash do
  @moduledoc "Bash preflight configuration and dedicated-tool routing defaults."

  @rules [
    %{
      "pattern" => "^(cat|head|tail|less|more)\\s+",
      "tool" => "read",
      "message" => "Use read for file contents."
    },
    %{
      "pattern" => "^(grep|rg|ripgrep|ag|ack)\\s+",
      "tool" => "grep",
      "message" => "Use grep for file content searches."
    },
    %{
      "pattern" => "^(find|fd|locate)(\\s|$)",
      "tool" => "find",
      "message" => "Use find for file discovery."
    },
    %{"pattern" => "^ls(\\s|$)", "tool" => "ls", "message" => "Use ls for directory listings."},
    %{
      "pattern" => "^sed\\b.*\\s(?:-[^-\\s]*i|--in-place)(?:\\S*)(?:\\s|$)",
      "tool" => "edit",
      "message" => "Use edit for in-place changes."
    },
    %{
      "pattern" => "^perl\\b.*\\s-[^-\\s]*i",
      "tool" => "edit",
      "message" => "Use edit for in-place changes."
    }
  ]

  def defaults, do: %{"interceptor" => %{"enabled" => false, "rules" => @rules}}

  def resolve(section) when is_map(section) do
    interceptor = Map.get(section, "interceptor", %{})
    %{interceptor: resolve_interceptor(interceptor)}
  end

  def resolve(invalid), do: invalid

  defp resolve_interceptor(section) when is_map(section),
    do: %{enabled: Map.get(section, "enabled", false), rules: Map.get(section, "rules", @rules)}

  defp resolve_interceptor(invalid), do: invalid

  def validate(errors, nil), do: errors

  def validate(errors, %{interceptor: %{enabled: enabled, rules: rules}}) do
    errors =
      if is_boolean(enabled),
        do: errors,
        else: ["runtime.tools.bash.interceptor.enabled: must be a boolean" | errors]

    validate_rules(errors, rules)
  end

  def validate(errors, _), do: ["runtime.tools.bash.interceptor: must be a table" | errors]

  defp validate_rules(errors, rules) when is_list(rules) do
    Enum.reduce(rules, errors, fn rule, errors ->
      if valid_rule?(rule),
        do: errors,
        else: [
          "runtime.tools.bash.interceptor.rules: each rule requires a valid regex pattern, tool and message strings"
          | errors
        ]
    end)
  end

  defp validate_rules(errors, _),
    do: ["runtime.tools.bash.interceptor.rules: must be a list" | errors]

  defp valid_rule?(%{"pattern" => pattern, "tool" => tool, "message" => message})
       when is_binary(pattern) and is_binary(tool) and is_binary(message),
       do: tool != "" and message != "" and match?({:ok, _}, Regex.compile(pattern))

  defp valid_rule?(_), do: false
end
