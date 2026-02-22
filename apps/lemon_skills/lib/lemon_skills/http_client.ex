defmodule LemonSkills.HttpClient do
  @moduledoc "Behaviour for HTTP fetching, injectable for testing."

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
end
