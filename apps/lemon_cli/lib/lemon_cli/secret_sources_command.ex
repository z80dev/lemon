defmodule LemonCli.SecretSourcesCommand do
  @moduledoc false

  @exit_ok 0
  @exit_error 1
  @exit_usage 2
  @source_id ~r/^[a-z][a-z0-9_-]{0,63}$/

  alias LemonCore.Secrets.External

  @spec run([String.t()]) :: 0 | 1 | 2
  def run(["status" | args]), do: run_status(args)
  def run(["test" | args]), do: run_test(args)

  def run(_args) do
    usage(:stderr)
    @exit_usage
  end

  defp run_status(args) do
    with {:ok, opts, []} <- parse(args, false),
         nil <- opts[:source_id] do
      result = External.status(project_dir: opts[:project_dir] || File.cwd!())
      print(result, opts[:json] || false, :status)
      @exit_ok
    else
      _ ->
        usage(:stderr)
        @exit_usage
    end
  end

  defp run_test(args) do
    with {:ok, opts, positional} <- parse(args, true),
         {:ok, source_id} <- parse_source_id(opts[:source_id], positional) do
      result =
        External.test(
          project_dir: opts[:project_dir] || File.cwd!(),
          source_id: source_id
        )

      print(result, opts[:json] || false, :test)
      if result.status == :ready, do: @exit_ok, else: @exit_error
    else
      _ ->
        usage(:stderr)
        @exit_usage
    end
  end

  defp parse(args, allow_positional?) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [project_dir: :string, source_id: :string, json: :boolean]
      )

    cond do
      invalid != [] -> {:error, :invalid_options}
      not allow_positional? and positional != [] -> {:error, :unexpected_arguments}
      true -> {:ok, opts, positional}
    end
  end

  defp parse_source_id(nil, []), do: {:ok, nil}

  defp parse_source_id(id, []) when is_binary(id),
    do: validate_source_id(id)

  defp parse_source_id(nil, [id]) when is_binary(id),
    do: validate_source_id(id)

  defp parse_source_id(_id, _positional), do: {:error, :usage}

  defp validate_source_id(id) do
    if Regex.match?(@source_id, id), do: {:ok, id}, else: {:error, :usage}
  end

  defp print(result, true, _mode), do: IO.puts(Jason.encode!(result, pretty: true))

  defp print(result, false, :status) do
    IO.puts("External secret sources")
    IO.puts("Status: #{result.status}")
    IO.puts("Configured: #{result.configured_count}")
    IO.puts("Enabled: #{result.enabled_count}")
    IO.puts("Configuration errors: #{result.config_error_count}")

    Enum.each(result.sources, fn source ->
      IO.puts(
        "#{source.id} type=#{source.type} status=#{source.status} " <>
          "executable=#{yes_no(source.executable_available)} " <>
          "bootstrap=#{yes_no(source.bootstrap_available)} " <>
          "provenance=#{source.provenance}"
      )
    end)

    print_config_errors(result.config_errors)
    IO.puts("Secret values included: no")
  end

  defp print(result, false, :test) do
    IO.puts("External secret source test")
    IO.puts("Status: #{result.status}")
    IO.puts("Tested: #{result.tested_count}")

    Enum.each(result.results, fn source ->
      suffix =
        case source do
          %{status: :ready} ->
            "secrets=#{source.secret_count} bytes=#{source.output_bytes}"

          %{error_kind: reason} ->
            "error=#{reason}"
        end

      IO.puts(
        "#{source.id} type=#{source.type} status=#{source.status} #{suffix} " <>
          "provenance=#{source.provenance}"
      )
    end)

    print_config_errors(result.config_errors)
    IO.puts("Secret values included: no")
  end

  defp print_config_errors([]), do: :ok
  defp print_config_errors(errors), do: Enum.each(errors, &IO.puts("Config: #{&1}"))

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp usage(device) do
    IO.puts(device, "Usage: lemon secrets sources <status|test> [source-id] [options]")
    IO.puts(device, "  --project-dir PATH   Resolve project configuration from PATH")
    IO.puts(device, "  --source-id ID       Test one enabled source")
    IO.puts(device, "  --json               Emit readiness/provenance JSON without secret values")
  end
end
