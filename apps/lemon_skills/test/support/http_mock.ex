defmodule LemonSkills.HttpClient.Mock do
  @moduledoc """
  Deterministic HTTP mock for LemonSkills tests.

  Stores URL->response mappings in the process dictionary so tests can
  set up expected responses without external dependencies.

  ## Usage

      # In test setup:
      LemonSkills.HttpClient.Mock.reset()
      LemonSkills.HttpClient.Mock.stub("https://api.github.com/...", {:ok, ~s({"items": []})})

      # Or stub an error:
      LemonSkills.HttpClient.Mock.stub("https://example.com/fail", {:error, :timeout})
  """

  @behaviour LemonSkills.HttpClient

  @agent_key :http_mock_agent

  # --------------------------------------------------------------------------
  # Setup helpers
  # --------------------------------------------------------------------------

  @doc "Start (or restart) the mock agent, clearing all stubs."
  def reset do
    case Process.whereis(@agent_key) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end

    {:ok, _pid} = Agent.start_link(fn -> %{} end, name: @agent_key)
    :ok
  end

  @doc "Register a stub response for a URL (prefix match supported)."
  def stub(url_prefix, response) when is_binary(url_prefix) do
    Agent.update(@agent_key, fn stubs ->
      Map.put(stubs, url_prefix, response)
    end)
  end

  @doc "Return the current stub map (useful for debugging)."
  def stubs do
    Agent.get(@agent_key, & &1)
  end

  # --------------------------------------------------------------------------
  # Behaviour implementation
  # --------------------------------------------------------------------------

  @impl true
  def fetch(url, _headers) do
    stubs = Agent.get(@agent_key, & &1)

    # Try exact match first, then prefix match (longest prefix wins)
    case Map.fetch(stubs, url) do
      {:ok, response} ->
        response

      :error ->
        # Find longest matching prefix
        match =
          stubs
          |> Enum.filter(fn {prefix, _} -> String.starts_with?(url, prefix) end)
          |> Enum.sort_by(fn {prefix, _} -> -String.length(prefix) end)
          |> List.first()

        case match do
          {_prefix, response} -> response
          nil -> {:error, {:no_stub, url}}
        end
    end
  end
end
