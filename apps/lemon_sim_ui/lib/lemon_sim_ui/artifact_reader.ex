defmodule LemonSimUi.ArtifactReader do
  @moduledoc false

  require Logger

  @suite_schema "lemon_sim.suite.v1"
  @usage_schema "lemon_sim.usage.v1"
  @default_suite_roots ["/tmp/vending-suite"]

  def list_suites do
    suite_roots()
    |> Enum.flat_map(&suite_paths/1)
    |> Enum.uniq()
    |> Enum.flat_map(&read_suite/1)
    |> Enum.sort_by(& &1.created_at_sort, {:desc, DateTime})
  end

  def read_usage(nil), do: nil

  def read_usage(artifact_dir) when is_binary(artifact_dir) do
    path = Path.join(artifact_dir, "usage.json")

    with {:ok, body} <- File.read(path),
         {:ok, %{"schema" => @usage_schema} = usage} <- Jason.decode(body),
         %{} = actors <- usage["actors"] || %{} do
      Map.put(usage, "actors", actors)
    else
      {:error, :enoent} ->
        nil

      error ->
        Logger.warning("Skipping malformed LemonSim usage artifact #{path}: #{inspect(error)}")
        nil
    end
  end

  def format_cost(nil), do: "—"

  def format_cost(value) when is_number(value) do
    "$#{:erlang.float_to_binary(value / 1, decimals: 2)}"
  end

  def format_cost(_value), do: "—"

  def format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_integer(value) when is_number(value), do: value |> round() |> format_integer()
  def format_integer(_value), do: "0"

  def format_number(value) when is_integer(value), do: format_integer(value)

  def format_number(value) when is_float(value) do
    :erlang.float_to_binary(value, [:compact, decimals: 2])
  end

  def format_number(value) when is_binary(value), do: value
  def format_number(value), do: to_string(value)

  def total_tokens(usage) when is_map(usage) do
    Enum.reduce(~w(input_tokens output_tokens cache_read_tokens cache_write_tokens), 0, fn key,
                                                                                           acc ->
      acc + (get_key(usage, key) || 0)
    end)
  end

  def total_tokens(_usage), do: 0

  defp suite_roots do
    case Application.get_env(:lemon_sim_ui, :suite_roots, @default_suite_roots) do
      roots when is_list(roots) -> Enum.filter(roots, &is_binary/1)
      root when is_binary(root) -> [root]
      _ -> @default_suite_roots
    end
  end

  defp suite_paths(root) do
    direct = Path.join(root, "suite.json")
    nested = Path.wildcard(Path.join(root, "*/suite.json"))

    if File.exists?(direct), do: [direct | nested], else: nested
  end

  defp read_suite(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"schema_version" => @suite_schema} = suite} <- Jason.decode(body) do
      # decorate_suite indexes into nested artifact content; a schema-tagged
      # but shape-broken file must skip this one suite, never crash the page.
      [decorate_suite(path, suite)]
    else
      error ->
        Logger.warning("Skipping malformed LemonSim suite artifact #{path}: #{inspect(error)}")
        []
    end
  rescue
    error ->
      Logger.warning("Skipping malformed LemonSim suite artifact #{path}: #{inspect(error)}")
      []
  end

  defp decorate_suite(path, suite) do
    created_at = created_at(path, suite)
    spec = suite["spec"] || %{}

    %{
      # Opaque, stable id — this page is public, so absolute server paths
      # must not leak into the DOM or URLs.
      id: suite_slug(path),
      path: path,
      suite_dir: Path.dirname(path),
      dir_label: path |> Path.dirname() |> Path.basename(),
      created_at: format_created_at(created_at),
      created_at_sort: created_at,
      scenario: spec["scenario"] || "unknown",
      preset: spec["preset"] || "default",
      competitors: competitor_ids(spec["competitors"] || []),
      suite: suite
    }
  end

  defp suite_slug(path) do
    :crypto.hash(:sha256, path) |> Base.url_encode64(padding: false) |> binary_part(0, 12)
  end

  defp created_at(path, suite) do
    metadata = suite["metadata"] || %{}

    with value when is_binary(value) <- metadata["created_at"] || suite["created_at"],
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      datetime
    else
      _ -> file_mtime(path)
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> DateTime.from_unix!(mtime)
      _ -> DateTime.from_unix!(0)
    end
  end

  defp format_created_at(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp competitor_ids(competitors) do
    competitors
    |> Enum.map(fn competitor ->
      competitor["id"] || competitor["model"] || competitor["offline_strategy"]
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Keys come from a hardcoded whitelist, but avoid creating atoms from
  # artifact-derived strings on every call anyway.
  defp get_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp get_key(_map, _key), do: nil
end
