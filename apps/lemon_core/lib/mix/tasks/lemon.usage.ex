defmodule Mix.Tasks.Lemon.Usage do
  @moduledoc """
  Show redacted usage, cost, token, and quota diagnostics.

  ## Usage

      mix lemon.usage
      mix lemon.usage --json

  ## Options

    * `--json` - Emit the raw redacted usage diagnostics JSON.
  """

  use Mix.Task

  alias LemonCore.UsageDiagnostics

  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    Mix.Task.run("app.start")

    status = UsageDiagnostics.status()

    if opts[:json] do
      Mix.shell().info(Jason.encode!(status, pretty: true))
    else
      print_text(status)
    end
  end

  defp print_text(status) do
    cleanup = Map.get(status, :cleanup, %{})
    tokens = Map.get(status, :total_tokens, %{})
    today = Map.get(status, :today, %{})

    Mix.shell().info("Lemon Usage")
    Mix.shell().info("Status: #{Map.get(status, :status, "unknown")}")
    Mix.shell().info("Period: #{Map.get(status, :period, "current")}")
    Mix.shell().info("Requests: #{Map.get(status, :total_requests, 0)}")
    Mix.shell().info("Cost: #{format_money(Map.get(status, :total_cost, 0.0))}")
    Mix.shell().info("Tokens input: #{Map.get(tokens, :input, 0)}")
    Mix.shell().info("Tokens output: #{Map.get(tokens, :output, 0)}")
    Mix.shell().info("Tokens total: #{Map.get(tokens, :total, 0)}")

    Mix.shell().info(
      "Today: #{Map.get(today, :date, "unknown")} requests=#{Map.get(today, :requests, 0)} cost=#{format_money(Map.get(today, :cost, 0.0))}"
    )

    Mix.shell().info("Includes prompts: #{truthy?(cleanup[:includes_prompts])}")
    Mix.shell().info("Includes responses: #{truthy?(cleanup[:includes_responses])}")
    Mix.shell().info("Includes message bodies: #{truthy?(cleanup[:includes_message_bodies])}")
    Mix.shell().info("Includes credentials: #{truthy?(cleanup[:includes_credentials])}")
    Mix.shell().info("Includes secret values: #{truthy?(cleanup[:includes_secret_values])}")
    print_quotas(Map.get(status, :quotas, %{}))
    print_providers(Map.get(status, :providers, []))
  end

  defp print_quotas(quotas) do
    Mix.shell().info("Quotas:")
    Mix.shell().info("  runs_limit: #{display_limit(quotas[:runs_limit])}")
    Mix.shell().info("  tokens_limit: #{display_limit(quotas[:tokens_limit])}")
    Mix.shell().info("  cost_limit: #{display_limit(quotas[:cost_limit])}")
  end

  defp print_providers([]) do
    Mix.shell().info("Providers: none")
  end

  defp print_providers(providers) do
    Mix.shell().info("Providers:")

    Enum.each(providers, fn provider ->
      Mix.shell().info(
        "  #{provider.provider}: requests=#{provider.requests} cost=#{format_money(provider.cost)} input_tokens=#{provider.input_tokens} output_tokens=#{provider.output_tokens}"
      )
    end)
  end

  defp display_limit(nil), do: "unlimited"
  defp display_limit(limit), do: to_string(limit)

  defp format_money(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 4)

  defp format_money(_), do: "0.0000"

  defp truthy?(value), do: if(value, do: "true", else: "false")
end
