defmodule LemonAi.Preconnect do
  @moduledoc """
  Best-effort, unpaid connection warming for the stock Req.Finch pool.

  Sends an unauthenticated HEAD to the selected model's origin, never a model
  request. No redirects, credentials, prompt, retries or response body are sent.
  Hints are asynchronous, coalesced per origin for 30 seconds and bounded to eight
  distinct origins per 30-second window, with at most eight concurrent tasks.
  Failure never changes model-call admission or results.
  A server may close the connection; warming is not a latency guarantee.
  """
  use GenServer

  alias LemonAi.Types.Model

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Queues an optional warm-up hint; invalid or unavailable hints are ignored."
  def hint(%Model{} = model) do
    _ =
      with {:ok, origin} <- origin(model), pid when is_pid(pid) <- Process.whereis(__MODULE__) do
        GenServer.cast(pid, {:hint, origin})
      end

    :ok
  end

  @doc false
  def origin(%Model{base_url: url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, URI.to_string(%{uri | path: "/", query: nil, fragment: nil})}

      _ ->
        {:error, :unsupported_origin}
    end
  end

  def origin(_), do: {:error, :unsupported_origin}

  @impl true
  def init(opts), do: {:ok, %{origins: %{}, request: Keyword.get(opts, :request, &warm/1)}}

  @impl true
  def handle_cast({:hint, origin}, state) do
    now = System.monotonic_time(:millisecond)
    origins = Map.filter(state.origins, fn {_origin, expiry} -> expiry > now end)

    if map_size(origins) < 8 and not Map.has_key?(origins, origin) do
      request = state.request
      _ = Task.Supervisor.start_child(LemonAi.PreconnectTasks, fn -> request.(origin) end)
      {:noreply, %{state | origins: Map.put(origins, origin, now + 30_000)}}
    else
      {:noreply, %{state | origins: origins}}
    end
  end

  defp warm(origin) do
    # Provider requests use stock Req, whose default Finch name is Req.Finch.
    # Calling Finch directly avoids Req default headers, redirects and retries.
    Finch.build(:head, origin)
    |> Finch.request(Req.Finch, receive_timeout: 1_000, pool_timeout: 100)
  end
end
