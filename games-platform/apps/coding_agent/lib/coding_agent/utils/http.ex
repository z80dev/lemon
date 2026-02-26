defmodule CodingAgent.Utils.Http do
  @moduledoc """
  HTTP utility functions for header handling and content-type parsing.
  """

  @doc """
  Checks if a header key matches a given key (case-insensitive).

  ## Examples
      iex> header_key_match?("Content-Type", "content-type")
      true
      iex> header_key_match?(:"X-Custom", "x-custom")
      true
      iex> header_key_match?("Authorization", "content-type")
      false
  """
  @spec header_key_match?(String.t() | atom(), String.t()) :: boolean()
  def header_key_match?(header_key, key) when is_atom(header_key) do
    header_key_match?(Atom.to_string(header_key), key)
  end

  def header_key_match?(header_key, key) when is_binary(header_key) do
    String.downcase(header_key) == String.downcase(key)
  end

  @doc """
  Parses a content-type header value, returning {type, params}.

  ## Examples
      iex> parse_content_type("application/json; charset=utf-8")
      {"application/json", "charset=utf-8"}
      iex> parse_content_type("text/html")
      {"text/html", nil}
  """
  @spec parse_content_type(String.t()) :: {String.t(), String.t() | nil}
  def parse_content_type(content_type) do
    case String.split(content_type, ";", parts: 2) do
      [type] -> {String.trim(type), nil}
      [type, params] -> {String.trim(type), String.trim(params)}
    end
  end
end
