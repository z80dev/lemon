defmodule LemonCli.ContextCommand do
  @moduledoc "Packaged CLI adapter for the canonical `LemonCore.Context` service."

  alias LemonCore.Context
  alias LemonCli.Onboarding.LogSilencer

  @exit_ok 0
  @exit_error 1
  @exit_usage 2

  @spec run([String.t()]) :: 0 | 1 | 2
  def run([action | args]) when action in ["preview", "resolve"] do
    {opts, references, invalid} =
      OptionParser.parse(args,
        strict: [
          root: :string,
          json: :boolean,
          max_bytes: :integer,
          max_input_bytes: :integer,
          max_items: :integer,
          max_pages: :integer,
          max_depth: :integer,
          timeout_ms: :integer
        ]
      )

    cond do
      invalid != [] ->
        usage_error("Invalid options: #{inspect(invalid)}")

      references == [] ->
        usage_error("At least one context reference is required")

      true ->
        json? = opts[:json] == true

        result =
          LogSilencer.with_quiet_logs(json?, fn ->
            _ = Application.ensure_all_started(:lemon_core)
            service_opts = service_opts(opts)

            if action == "preview",
              do: Context.preview(references, service_opts),
              else: Context.resolve(references, service_opts)
          end)

        case result do
          {:ok, response} ->
            print_response(response, json?)
            @exit_ok

          {:error, reason} ->
            IO.puts(:stderr, "Context #{action} failed: #{format_reason(reason)}")
            @exit_error
        end
    end
  end

  def run(_args), do: usage_error("Expected `preview` or `resolve`")

  @spec print_usage(IO.device()) :: :ok
  def print_usage(device \\ :stdio) do
    IO.puts(device, """
    Usage: lemon context <preview|resolve> <reference>... [options]

    References:
      @file:<path>          One root-confined file (documents are sniffed)
      @folder:<path>        A bounded, non-symlink folder walk
      @git-diff[:selector]  Working tree, staged, or a safe revision
      @url:<https-url>      Public URL with SSRF/redirect defenses
      @session:<key>        Canonical redacted session export

    Options:
      --root PATH             Local-reference and git root (default: cwd)
      --max-bytes N           Selected output budget
      --max-input-bytes N     Per-source compressed/input byte limit
      --max-items N           Reference/archive/folder/notebook item limit
      --max-pages N           PDF/PPTX page or slide limit
      --max-depth N           Folder/JSON depth limit
      --timeout-ms N          Whole-operation timeout (hard-capped at 60000)
      --json                  Emit the complete redacted contract as JSON
    """)
  end

  defp service_opts(opts) do
    []
    |> put(:root, opts[:root])
    |> put(:max_output_bytes, opts[:max_bytes])
    |> put(:max_input_bytes, opts[:max_input_bytes])
    |> put(:max_items, opts[:max_items])
    |> put(:max_pages, opts[:max_pages])
    |> put(:max_depth, opts[:max_depth])
    |> put(:timeout_ms, opts[:timeout_ms])
  end

  defp put(keyword, _key, nil), do: keyword
  defp put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp print_response(response, true), do: IO.puts(Jason.encode!(response, pretty: true))

  defp print_response(response, false) do
    summary = response.summary

    IO.puts(
      "Context #{response.mode}: #{summary.selected_sources} source(s), " <>
        "#{summary.selected_bytes} selected byte(s), #{summary.omitted_count} omission(s), " <>
        "#{summary.redaction_count} redaction(s)"
    )

    Enum.each(response.sources, fn source ->
      IO.puts("- #{source.type}: #{source.label} (#{source.selected_items} item(s))")
    end)

    Enum.each(response.omissions, fn omission ->
      IO.puts(:stderr, "Omitted #{omission.reference}: #{omission.reason}")
    end)

    if is_binary(response.selected_text) and response.selected_text != "" do
      IO.puts("\n" <> response.selected_text)
    end
  end

  defp usage_error(message) do
    IO.puts(:stderr, message)
    print_usage(:stderr)
    @exit_usage
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason({reason, _, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(_), do: "unavailable"
end
