defmodule LemonCore.PidFile do
  @moduledoc "OS process identity records. Never signals the recorded process."

  def live?(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, contents} <- File.read(path),
         [pid | rest] <- String.split(contents, "\n"),
         {pid, ""} when pid > 0 <- Integer.parse(String.trim(pid)) do
      process_alive?(pid, rest |> List.first("") |> String.trim())
    else
      _ -> false
    end
  end

  def write(path) do
    case process_start_time(System.pid()) do
      nil -> {:error, :process_identity_unavailable}
      born -> File.write(path, System.pid() <> "\n" <> born)
    end
  end

  def process_alive?(pid, born) do
    pid = to_string(pid)

    case System.cmd("ps", ["-p", pid, "-o", "stat="], stderr_to_stdout: true) do
      {state, 0} ->
        not String.contains?(state, "Z") and (born == "" or process_start_time(pid) == born)

      _ ->
        false
    end
  rescue
    _ -> true
  end

  def process_start_time(pid) do
    case System.cmd("ps", ["-p", to_string(pid), "-o", "lstart="], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
