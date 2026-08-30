defmodule LemonCli.LearnCommand do
  @moduledoc "Mix-free CLI adapter for the review-first `LemonSkills.Learn` service."

  alias LemonCli.Onboarding.LogSilencer

  @exit_ok 0
  @exit_error 1
  @exit_usage 2

  @strict [
    root: :string,
    agent_id: :string,
    session_key: :string,
    project: :boolean,
    confirm: :string,
    json: :boolean,
    max_bytes: :integer,
    max_input_bytes: :integer,
    max_items: :integer,
    max_pages: :integer,
    max_depth: :integer,
    timeout_ms: :integer
  ]

  @spec run([String.t()]) :: 0 | 1 | 2
  def run(args) when is_list(args) do
    {action, rest} =
      case args do
        [action | tail] when action in ["review", "confirm"] -> {action, tail}
        _ -> {"review", args}
      end

    {opts, references, invalid} = OptionParser.parse(rest, strict: @strict)

    cond do
      invalid != [] ->
        usage_error("Invalid learn options")

      references == [] ->
        usage_error("At least one source reference is required")

      action == "confirm" and is_nil(opts[:confirm]) ->
        usage_error("Confirm requires the exact digest from a fresh review")

      action == "review" and opts[:confirm] ->
        usage_error("--confirm is valid only with `lemon learn confirm`")

      true ->
        execute(action, references, opts)
    end
  end

  @spec print_usage(IO.device()) :: :ok
  def print_usage(device \\ :stdio) do
    IO.puts(device, """
    Usage: lemon learn [review] <reference>... [options]
           lemon learn confirm <reference>... --confirm <digest> [options]

    Review is the default and never writes state. Confirmation re-resolves all
    references and succeeds only when source content and destination conflicts
    still match the exact review digest.

    Options:
      --root PATH             Root for confined local sources (default: cwd)
      --agent-id ID           Durable memory owner (default: default)
      --session-key KEY       Explicit learning session key
      --project               Write the skill draft to the project scope
      --confirm DIGEST        Exact 64-character digest from review
      --max-bytes N           Bound selected source bytes
      --max-input-bytes N     Bound bytes read per source
      --max-items N           Bound folder/document items
      --max-pages N           Bound document pages/slides
      --max-depth N           Bound folder/archive depth
      --timeout-ms N          Bound the complete source resolution
      --json                  Emit one sanitized JSON document
    """)
  end

  defp execute(action, references, opts) do
    json? = opts[:json] == true

    result =
      LogSilencer.with_quiet_logs(json?, fn ->
        case Application.ensure_all_started(:lemon_skills) do
          {:ok, _} ->
            service_opts = service_opts(opts)

            if action == "review",
              do: learn_service().review(references, service_opts),
              else: learn_service().confirm(references, opts[:confirm], service_opts)

          _ ->
            {:error, {:unavailable, "The learning service is unavailable"}}
        end
      end)

    case result do
      {:ok, payload} ->
        output(payload, json?)
        @exit_ok

      {:error, {_code, message}} ->
        error(message, json?)
        @exit_error

      _ ->
        error("The learning operation failed safely", json?)
        @exit_error
    end
  end

  defp service_opts(opts) do
    []
    |> put(:root, opts[:root])
    |> put(:agent_id, opts[:agent_id])
    |> put(:session_key, opts[:session_key])
    |> put(:global, opts[:project] != true)
    |> put(:max_output_bytes, opts[:max_bytes])
    |> put(:max_input_bytes, opts[:max_input_bytes])
    |> put(:max_items, opts[:max_items])
    |> put(:max_pages, opts[:max_pages])
    |> put(:max_depth, opts[:max_depth])
    |> put(:timeout_ms, opts[:timeout_ms])
  end

  defp put(keyword, _key, nil), do: keyword
  defp put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp learn_service,
    do: Application.get_env(:lemon_cli, :learn_service, LemonSkills.Learn)

  defp output(payload, true), do: IO.puts(Jason.encode!(payload, pretty: true))

  defp output(payload, false) do
    IO.puts(
      "Learn #{payload["status"]}: #{payload["sources"]["count"]} source(s), #{payload["sources"]["selectedBytes"]} selected byte(s)"
    )

    IO.puts("Memory: #{payload["memory"]["action"]} #{payload["memory"]["id"]}")

    IO.puts(
      "Skill draft: #{payload["skill"]["action"]} #{payload["skill"]["key"]} (audit #{payload["skill"]["auditVerdict"]})"
    )

    if payload["status"] == "review" do
      IO.puts("Can confirm: #{payload["canConfirm"]}")
      IO.puts("Confirmation digest: #{payload["confirmationDigest"]}")
    end

    if payload["conflicts"] != [],
      do: IO.puts("Conflicts: #{Enum.join(payload["conflicts"], ", ")}")
  end

  defp error(message, true),
    do: IO.puts(:stderr, Jason.encode!(%{"error" => "learn_failed", "message" => message}))

  defp error(message, false), do: IO.puts(:stderr, "Learn failed: #{message}")

  defp usage_error(message) do
    IO.puts(:stderr, message)
    print_usage(:stderr)
    @exit_usage
  end
end
