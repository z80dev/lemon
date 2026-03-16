defmodule LemonSkills.HttpClient do
  @moduledoc """
  Behaviour for HTTP fetching, injectable for testing.

  Source modules (see `LemonSkills.Source`) use this behaviour to fetch skill
  manifests and registry metadata without depending on a concrete HTTP library.
  Override in tests:

      config :lemon_skills, :http_client, MyApp.FakeHttpClient
  """

  @callback fetch(url :: String.t(), headers :: [{String.t(), String.t()}]) ::
              {:ok, body :: String.t()} | {:error, reason :: any()}

  @doc """
  Returns the configured HTTP client module.

  Defaults to `LemonSkills.HttpClient.Httpc` when no override is set.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:lemon_skills, :http_client, LemonSkills.HttpClient.Httpc)
  end

  @doc """
  Convenience wrapper: fetch a URL with no extra headers.

  Delegates to `impl().fetch/2` using an empty header list.
  """
  @spec get(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get(url) when is_binary(url) do
    impl().fetch(url, [])
  end
end
