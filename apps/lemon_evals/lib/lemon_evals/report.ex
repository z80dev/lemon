defmodule LemonEvals.Report do
  @moduledoc """
  Versioned, allowlisted artifacts for the existing contract evaluation suite.

  Artifacts retain code-authored check identifiers and pass/fail status, not
  raw result details, transcripts, tool arguments, exception messages, paths,
  provider URLs, or credential configuration. Check identifiers must be stable
  non-sensitive names authored by the suite. Unknown fields are discarded.

  `iterations` records the configured statistical-check iteration count; it
  does not imply that each live-model check ran that many independent trials.
  Revision is supplied explicitly rather than reading environment variables or
  invoking Git. Missing revision is represented by null, never guessed.
  """

  @spec valid_revision?(term()) :: boolean()
  def valid_revision?(nil), do: true

  def valid_revision?(revision) when is_binary(revision),
    do: Regex.match?(~r/\A[0-9a-f]{40}\z/i, revision)

  def valid_revision?(_revision), do: false

  @spec build(map(), keyword()) :: map()
  def build(%{results: results}, opts \\ []) when is_list(results) do
    revision = Keyword.get(opts, :revision)

    unless valid_revision?(revision) do
      raise ArgumentError, "revision must be a full 40-character Git commit SHA"
    end

    rows = Enum.map(results, &project_result/1)

    %{
      schema_version: 1,
      suite: "lemon_contracts",
      recorded_at: DateTime.to_iso8601(DateTime.utc_now()),
      revision: revision,
      runtime: %{
        elixir: System.version(),
        otp: System.otp_release()
      },
      configuration: %{
        iterations: positive_integer(opts, :iterations, 25),
        live_model: Keyword.get(opts, :live_model, false) == true,
        live_timeout_ms: positive_integer(opts, :live_timeout_ms, 90_000)
      },
      duration_ms: non_negative_integer(opts, :duration_ms, 0),
      summary: %{
        passed: Enum.count(rows, &(&1.status == "pass")),
        failed: Enum.count(rows, &(&1.status == "fail"))
      },
      results: rows
    }
  end

  @doc "Write a report through an exclusive sibling file, then rename into place."
  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(path, report) when is_binary(path) and is_map(report) do
    temp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(report, pretty: true),
         {:ok, file} <- File.open(temp, [:write, :binary, :exclusive]) do
      try do
        write_result = IO.binwrite(file, json <> "\n")
        close_result = File.close(file)

        with :ok <- write_result,
             :ok <- close_result do
          File.rename(temp, path)
        end
      after
        File.close(file)
        File.rm(temp)
      end
    end
  end

  defp project_result(%{name: name, status: status})
       when is_binary(name) and status in [:pass, :fail] do
    unless Regex.match?(~r/\A[a-z][a-z0-9_]{0,127}\z/, name) do
      raise ArgumentError, "eval check identifiers must be stable lowercase names"
    end

    %{name: name, status: Atom.to_string(status)}
  end

  defp project_result(_result), do: raise(ArgumentError, "invalid eval result shape")

  defp positive_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> raise ArgumentError, "eval report requires a positive #{key}"
    end
  end

  defp non_negative_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> raise ArgumentError, "eval report requires a non-negative #{key}"
    end
  end
end
