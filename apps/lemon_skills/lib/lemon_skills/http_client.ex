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

  Defaults to `LemonSkills.HttpClient.Guarded` (`LemonCore.Net.HTTP`) when no
  override is set.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:lemon_skills, :http_client, LemonSkills.HttpClient.Guarded)
  end
end
