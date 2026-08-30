defmodule CodingAgent.Search.Result do
  @moduledoc false

  alias CodingAgent.Security.ExternalContent

  def decode_json(body) when is_map(body), do: body

  def decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  def decode_json(body) when is_list(body), do: body |> IO.iodata_to_binary() |> decode_json()
  def decode_json(_), do: %{}

  def search_results(query, provider, raw_results, started_ms) do
    results = Enum.reject(raw_results, &is_nil/1)

    %{
      "query" => query,
      "provider" => provider,
      "count" => length(results),
      "took_ms" => elapsed_ms(started_ms),
      "results" => results,
      "trust_metadata" =>
        ExternalContent.web_trust_metadata(
          :web_search,
          ["results[].title", "results[].description"],
          warning_included: false
        )
    }
  end

  def mapped_result(title, url, description, opts \\ []) do
    title = title |> optional_string() |> truncate(Keyword.get(opts, :title_max_chars, 600))

    description =
      description
      |> optional_string()
      |> truncate(Keyword.get(opts, :description_max_chars, 12_000))

    url = optional_string(url)

    if is_nil(url) and is_nil(title) and is_nil(description) do
      nil
    else
      %{
        "title" => wrap(title),
        "url" => url || "",
        "description" => wrap(description),
        "published" => optional_string(Keyword.get(opts, :published)),
        "site_name" => Keyword.get(opts, :site_name) || site_name(url)
      }
    end
  end

  def wrap(nil), do: ""
  def wrap(value), do: ExternalContent.wrap_web_content(value, :web_search)

  def truncate(nil, _max_chars), do: nil

  def truncate(value, max_chars)
      when is_binary(value) and is_integer(max_chars) and max_chars > 0 do
    if String.length(value) <= max_chars do
      value
    else
      String.slice(value, 0, max_chars) <> "..."
    end
  end

  def optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def optional_string(_), do: nil

  def to_string_safe(value) when is_binary(value), do: value
  def to_string_safe(value) when is_list(value), do: IO.iodata_to_binary(value)
  def to_string_safe(value), do: inspect(value)

  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_reason(reason), do: inspect(reason)

  def elapsed_ms(started_ms), do: System.monotonic_time(:millisecond) - started_ms

  defp site_name(nil), do: nil

  defp site_name(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end
end
