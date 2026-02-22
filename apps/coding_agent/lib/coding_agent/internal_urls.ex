defmodule CodingAgent.InternalUrls do
  @moduledoc """
  Router for internal URL protocols.

  Dispatches internal URL requests to the appropriate protocol handler
  based on the URL scheme.

  ## Supported Protocols

    * `notes://` - Session-scoped artifact storage (see `CodingAgent.InternalUrls.NotesProtocol`)
  """

  alias CodingAgent.InternalUrls.NotesProtocol

  # ============================================================================
  # Routing
  # ============================================================================

  @doc """
  Resolve an internal URL to a filesystem path.

  Dispatches to the appropriate protocol handler based on URL scheme.

  ## Parameters

    * `url` - The internal URL string
    * `opts` - Resolution options passed to the protocol handler

  ## Returns

    * `{:ok, path}` - The resolved filesystem path
    * `{:error, reason}` - Resolution failure
  """
  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def resolve("notes://" <> _ = url, opts) do
    NotesProtocol.resolve(url, opts)
  end

  def resolve(_url, _opts), do: {:error, :unknown_protocol}

  @doc """
  Check if a URL uses a known internal protocol scheme.

  ## Parameters

    * `url` - The URL string to check

  ## Returns

  `true` if the URL uses a known internal protocol scheme.
  """
  @spec internal_url?(String.t()) :: boolean()
  def internal_url?("notes://" <> _), do: true
  def internal_url?(_), do: false

  @doc """
  Parse any internal URL.

  ## Parameters

    * `url` - The internal URL string

  ## Returns

    * `{:ok, parsed}` - Successfully parsed URL
    * `{:error, reason}` - Parse failure
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, atom()}
  def parse("notes://" <> _ = url) do
    NotesProtocol.parse_notes_url(url)
  end

  def parse(_), do: {:error, :unknown_protocol}
end
