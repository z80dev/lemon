# Debug inspection script for lemon gateway
IO.puts("=== REGISTERED PROCESSES ===")
registered = :erlang.registered() |> Enum.sort()
registered |> IO.inspect(limit: :infinity)

IO.puts("\n=== RUNNING APPLICATIONS ===")
Application.started_applications() |> Enum.each(fn {app, _, _} -> IO.puts("  #{app}") end)

IO.puts("\n=== LEMON PROCESSES ===")
registered 
|> Enum.filter(fn name -> 
  name_str = to_string(name)
  String.contains?(name_str, "Lemon") or String.contains?(name_str, "lemon")
end)
|> IO.inspect(limit: :infinity)

# Try to get info about specific processes if they exist
try do
  IO.puts("\n=== TRYING LemonGateway.Scheduler ===")
  pid = Process.whereis(LemonGateway.Scheduler)
  if pid do
    IO.inspect(pid, label: "PID")
    IO.inspect(Process.info(pid), limit: 50)
  else
    IO.puts("LemonGateway.Scheduler not found")
  end
rescue e ->
  IO.puts("Error: #{inspect(e)}")
end

try do
  IO.puts("\n=== TRYING LemonGateway.EngineLock ===")
  pid = Process.whereis(LemonGateway.EngineLock)
  if pid do
    IO.inspect(pid, label: "PID")
    IO.inspect(Process.info(pid), limit: 50)
  else
    IO.puts("LemonGateway.EngineLock not found")
  end
rescue e ->
  IO.puts("Error: #{inspect(e)}")
end

try do
  IO.puts("\n=== TRYING ThreadWorkerSupervisor ===")
  pid = Process.whereis(LemonGateway.ThreadWorkerSupervisor)
  if pid do
    IO.inspect(pid, label: "PID")
    IO.inspect(Process.info(pid), limit: 50)
  else
    IO.puts("LemonGateway.ThreadWorkerSupervisor not found")
  end
rescue e ->
  IO.puts("Error: #{inspect(e)}")
end

IO.puts("\n=== ALL SUPERVISORS ===")
Process.list()
|> Enum.filter(fn pid -> 
  info = Process.info(pid, [:dictionary])
  info && info[:dictionary] && info[:dictionary][:"$initial_call"] == {:supervisor, :init, 1}
end)
|> Enum.take(20)
|> IO.inspect(limit: :infinity)

IO.puts("\n=== PROCESS COUNT ===")
IO.puts("Total processes: #{length(Process.list())}")
