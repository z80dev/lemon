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

  def wrap_fetch_content(value, max_chars) when is_binary(value) and is_integer(max_chars) do
    wrapper_with_warning = ExternalContent.wrap_web_content("", :web_fetch)

    wrapper_without_warning =
      ExternalContent.wrap_external_content("", source: :web_fetch, include_warning: false)

    include_warning = String.length(wrapper_with_warning) <= max_chars

    wrapper_overhead =
      if include_warning,
        do: String.length(wrapper_with_warning),
        else: String.length(wrapper_without_warning)

    max_inner = max(max_chars - wrapper_overhead, 0)
    {truncated, truncated?} = bounded_text(value, max_inner)
    wrapped = wrap_fetch_text(truncated, include_warning)

    {final_wrapped, final_truncated, final_raw} =
      if String.length(wrapped) > max_chars do
        adjusted_max_inner = max(max_inner - (String.length(wrapped) - max_chars), 0)
        {adjusted, adjusted_truncated?} = bounded_text(value, adjusted_max_inner)
        {wrap_fetch_text(adjusted, include_warning), adjusted_truncated?, adjusted}
      else
        {wrapped, truncated?, truncated}
      end

    %{
      text: final_wrapped,
      truncated: final_truncated,
      raw_length: String.length(final_raw),
      wrapped_length: String.length(final_wrapped),
      warning_included: include_warning
    }
  end

  def wrap_fetch_field(nil), do: nil
  def wrap_fetch_field(""), do: nil

  def wrap_fetch_field(value) do
    ExternalContent.wrap_external_content(to_string_safe(value),
      source: :web_fetch,
      include_warning: false
    )
  end

  def fetch_trust_metadata(wrapped, wrapped_title \\ nil) do
    wrapped_fields = if wrapped_title in [nil, ""], do: ["text"], else: ["text", "title"]

    ExternalContent.web_trust_metadata(:web_fetch, wrapped_fields,
      key_style: :camel_case,
      warning_included: wrapped.warning_included
    )
  end

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

  defp bounded_text(value, max_chars) do
    if String.length(value) <= max_chars do
      {value, false}
    else
      {String.slice(value, 0, max_chars), true}
    end
  end

  defp wrap_fetch_text(content, true), do: ExternalContent.wrap_web_content(content, :web_fetch)

  defp wrap_fetch_text(content, false) do
    ExternalContent.wrap_external_content(content, source: :web_fetch, include_warning: false)
  end

  defp site_name(nil), do: nil

  defp site_name(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end
end
