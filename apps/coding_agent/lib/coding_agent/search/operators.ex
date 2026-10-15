defmodule CodingAgent.Search.Operators do
  @moduledoc "Parses search directives and adapts them to declared provider features."

  @filterable [:site, :exclude_site, :inurl, :filetype]
  @syntax [:site, :exclude_site, :inurl, :intitle, :filetype, :phrase, :exclude, :or]

  def syntax, do: @syntax

  def parse(query) do
    Regex.scan(~r/(?:-?\w+:)?"[^"]*"|\S+/, query)
    |> Enum.map(fn [token] -> parse_token(token) end)
  end

  defp parse_token("OR"), do: %{kind: :or, value: "OR", raw: "OR"}

  defp parse_token("\"" <> rest = raw),
    do: %{kind: :phrase, value: String.trim_trailing(rest, "\""), raw: raw}

  defp parse_token(raw) do
    case String.split(raw, ":", parts: 2) do
      [name, value] when value != "" ->
        kind =
          %{
            "site" => :site,
            "-site" => :exclude_site,
            "inurl" => :inurl,
            "intitle" => :intitle,
            "filetype" => :filetype,
            "after" => :after,
            "before" => :before
          }[name]

        value = String.trim(value, "\"")

        if kind && (kind not in [:after, :before] or match?({:ok, _}, Date.from_iso8601(value))) do
          %{kind: kind, value: value, raw: raw}
        else
          %{kind: :term, value: raw, raw: raw}
        end

      _ ->
        if String.starts_with?(raw, "-") and byte_size(raw) > 1,
          do: %{kind: :exclude, value: String.slice(raw, 1..-1//1), raw: raw},
          else: %{kind: :term, value: raw, raw: raw}
    end
  end

  def prepare(query, features) do
    tokens = parse(query)
    native = Map.get(features, :operators, [])
    disjunction? = Enum.any?(tokens, &(&1.kind == :or)) and :or not in native
    mapped = if disjunction?, do: [], else: Map.get(features, :mapped_operators, [])
    # A flat URL filter cannot preserve disjunction semantics.
    filterable = if Enum.any?(tokens, &(&1.kind == :or)), do: [], else: @filterable
    kept = Enum.filter(tokens, &(&1.kind == :term or &1.kind in native))
    filters = Enum.filter(tokens, &(&1.kind in filterable and &1.kind not in native))

    dropped =
      Enum.reject(tokens, &(&1.kind == :term or &1.kind in (native ++ mapped ++ filterable)))

    %{
      query: Enum.map_join(kept, " ", & &1.raw),
      tokens: Enum.filter(tokens, &(&1.kind in (native ++ mapped))),
      filters: filters,
      dropped: Enum.map(dropped, & &1.raw)
    }
  end

  def finish(payload, original, prepared) do
    results = Map.get(payload, "results", []) |> Enum.filter(&matches?(&1, prepared.filters))

    payload =
      if Map.has_key?(payload, "citations"),
        do:
          Map.update!(payload, "citations", fn citations ->
            Enum.filter(citations, &matches?(%{"url" => &1}, prepared.filters))
          end),
        else: payload

    payload
    |> Map.put("query", original)
    |> Map.put("query_rewritten", prepared.query)
    |> Map.put("dropped_operators", prepared.dropped)
    |> Map.put("results", results)
    |> Map.put("count", length(results))
  end

  defp matches?(result, filters) do
    uri = URI.parse(result["url"] || "")
    sites = Enum.filter(filters, &(&1.kind == :site))

    (sites == [] or Enum.any?(sites, &site?(uri, &1.value))) and
      Enum.all?(Enum.reject(filters, &(&1.kind == :site)), fn token ->
        case token.kind do
          :exclude_site ->
            not site?(uri, token.value)

          :inurl ->
            String.contains?(String.downcase(result["url"] || ""), String.downcase(token.value))

          :filetype ->
            String.downcase(Path.extname(uri.path || "")) == "." <> String.downcase(token.value)
        end
      end)
  end

  defp site?(uri, value) do
    restriction =
      URI.parse(if String.contains?(value, "://"), do: value, else: "https://" <> value)

    host = String.downcase(uri.host || "")
    wanted = String.downcase(restriction.host || "")

    (host == wanted or String.ends_with?(host, "." <> wanted)) and
      String.starts_with?(uri.path || "/", restriction.path || "/")
  end

  def dates(request) do
    tokens = Map.get(request, :operator_tokens, [])
    after_date = Enum.find_value(tokens, &if(&1.kind == :after, do: &1.value))
    before_date = Enum.find_value(tokens, &if(&1.kind == :before, do: &1.value))

    if after_date || before_date do
      {after_date, before_date}
    else
      case Map.get(request, :freshness) do
        nil ->
          {nil, nil}

        "p" <> period when period in ["d", "w", "m", "y"] ->
          days = %{"d" => 1, "w" => 7, "m" => 30, "y" => 365}[period]
          {Date.utc_today() |> Date.add(-days) |> Date.to_iso8601(), nil}

        range ->
          case String.split(range, "to") do
            [first, last] -> {first, last}
            _ -> {nil, nil}
          end
      end
    end
  end

  def relative(request, values) do
    case Map.get(request, :freshness) do
      "pd" -> values[:day]
      "pw" -> values[:week]
      "pm" -> values[:month]
      "py" -> values[:year]
      _ -> nil
    end
  end

  def put_if(map, _key, nil), do: map
  def put_if(map, key, value), do: Map.put(map, key, value)
end
