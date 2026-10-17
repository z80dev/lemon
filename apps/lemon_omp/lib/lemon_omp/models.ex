defmodule LemonOmp.Models do
  @moduledoc """
  Bounded, sanitized omp catalog, cached for ten minutes per executable and mtime.
  Prices are omp catalog data, not a guarantee of upstream route availability.
  """
  use GenServer
  alias LemonOmp.{Config, Projection}

  @ttl 600_000
  @max_bytes 16 * 1024 * 1024

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  @impl true
  def init(_), do: {:ok, nil}

  def list(opts \\ []) do
    case Config.executable() do
      nil ->
        {:error, :not_installed}

      executable ->
        timeout = Application.get_env(:lemon_omp, :models_timeout_ms, 20_000)

        with {:ok, models} <-
               GenServer.call(__MODULE__, {:catalog, executable, timeout}, :infinity) do
          query = String.downcase(Projection.clean(opts[:query], 256))
          provider = String.downcase(Projection.clean(opts[:provider], 256))
          limit = if is_integer(opts[:limit]), do: min(200, max(1, opts[:limit])), else: 30

          {:ok,
           models
           |> Enum.filter(fn m ->
             (opts[:free_only] != true or m["free"]) and
               (provider == "" or String.downcase(m["provider"]) == provider) and
               String.contains?(String.downcase(m["selector"] <> " " <> m["name"]), query)
           end)
           |> Enum.take(limit)}
        end
    end
  end

  @impl true
  def handle_call({:catalog, executable, timeout}, _from, cache) do
    mtime =
      case File.stat(executable, time: :posix) do
        {:ok, stat} -> stat.mtime
        {:error, _} -> nil
      end

    key = {executable, mtime}
    now = System.monotonic_time(:millisecond)

    case cache do
      {^key, expires, models} when expires > now ->
        {:reply, {:ok, models}, cache}

      _ ->
        case fetch(executable, timeout) do
          {:ok, models} -> {:reply, {:ok, models}, {key, now + @ttl, models}}
          error -> {:reply, error, nil}
        end
    end
  end

  defp fetch(executable, timeout) do
    env =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "LEMON_"))
      |> Enum.map(&{String.to_charlist(&1), false})

    port =
      LemonCore.NativeProcess.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: [~c"models", ~c"--json"],
        env: env
      ])

    try do
      collect(port, [], 0, System.monotonic_time(:millisecond) + timeout)
    after
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          LemonCore.NativeProcess.cmd("kill", ["-KILL", Integer.to_string(pid)],
            stderr_to_stdout: true
          )

          close_port(port)

        nil ->
          :ok
      end
    end
  rescue
    _ -> {:error, {:catalog_failed, "could not launch omp models"}}
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp collect(port, chunks, size, deadline) do
    receive do
      {^port, {:data, data}} when size + byte_size(data) <= @max_bytes ->
        collect(port, [data | chunks], size + byte_size(data), deadline)

      {^port, {:data, _}} ->
        {:error, {:catalog_failed, "catalog output exceeded 16 MiB"}}

      {^port, {:exit_status, 0}} ->
        parse(chunks |> Enum.reverse() |> IO.iodata_to_binary())

      {^port, {:exit_status, status}} ->
        {:error, {:catalog_failed, "omp models exited with status #{status}"}}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        {:error, {:catalog_failed, "omp models timed out"}}
    end
  end

  defp parse(json) do
    case Jason.decode(json) do
      {:ok, %{"models" => models}} when is_list(models) -> project(models)
      {:ok, models} when is_list(models) -> project(models)
      _ -> {:error, {:catalog_failed, "invalid catalog JSON"}}
    end
  end

  defp project(models) do
    result =
      for m <- models,
          is_map(m),
          is_binary(m["selector"]),
          is_map(m["cost"]),
          input = m["cost"]["input"],
          output = m["cost"]["output"],
          is_number(input) and input >= 0 and is_number(output) and output >= 0 do
        strings = Map.new(~w(selector provider id name), &{&1, Projection.clean(m[&1], 512)})

        Map.merge(strings, %{
          "contextWindow" =>
            if(is_integer(m["contextWindow"]) and m["contextWindow"] >= 0,
              do: m["contextWindow"],
              else: nil
            ),
          "reasoning" => m["reasoning"] == true,
          "costInput" => input,
          "costOutput" => output,
          "free" => input == 0 and output == 0
        })
      end

    {:ok, Enum.sort_by(result, &{&1["costInput"] + &1["costOutput"], &1["name"], &1["selector"]})}
  end
end
