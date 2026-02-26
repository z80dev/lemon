# RPC debug inspection script
# Run with: elixir --sname debug2 --cookie lemon_gateway_dev_cookie debug_rpc.exs

node = :"lemon_gateway@chico"

IO.puts("=== CHECKING NODE: #{node} ===")
IO.puts("Ping result: #{Node.ping(node)}")

if Node.ping(node) == :pong do
  IO.puts("\n=== REGISTERED PROCESSES ===")
  registered = :rpc.call(node, :erlang, :registered, []) |> Enum.sort()
  registered |> IO.inspect(limit: :infinity)

  IO.puts("\n=== RUNNING APPLICATIONS ===")
  apps = :rpc.call(node, Application, :started_applications, [])
  apps |> Enum.each(fn {app, _, _} -> IO.puts("  #{app}") end)

  IO.puts("\n=== LEMON-RELATED PROCESSES ===")
  registered 
  |> Enum.filter(fn name -> 
    name_str = to_string(name)
    String.contains?(name_str, "Lemon") or String.contains?(name_str, "lemon") or 
    String.contains?(name_str, "Agent") or String.contains?(name_str, "agent")
  end)
  |> IO.inspect(limit: :infinity)

  # Try to get process info for key modules
  IO.puts("\n=== PROCESS INFO FOR KEY MODULES ===")
  
  key_modules = [
    LemonGateway.Scheduler,
    LemonGateway.EngineLock,
    LemonGateway.ThreadWorkerSupervisor,
    LemonGateway.SessionManager,
    LemonGateway.AgentRunner,
    LemonGateway.ConversationHandler
  ]
  
  for mod <- key_modules do
    try do
      pid = :rpc.call(node, Process, :whereis, [mod])
      if pid && is_pid(pid) do
        IO.puts("\n#{mod}: #{inspect(pid)}")
        info = :rpc.call(node, Process, :info, [pid, [:current_function, :status, :message_queue_len, :dictionary]])
        IO.inspect(info, limit: 30)
      else
        IO.puts("#{mod}: NOT RUNNING")
      end
    rescue e ->
      IO.puts("#{mod}: ERROR - #{inspect(e)}")
    end
  end
  
  IO.puts("\n=== ALL SUPERVISORS ===")
  pids = :rpc.call(node, Process, :list, [])
  IO.puts("Total processes: #{length(pids)}")
  
  # Get supervisor status
  IO.puts("\n=== SUPERVISOR STATUSES ===")
  for mod <- key_modules do
    try do
      pid = :rpc.call(node, Process, :whereis, [mod])
      if pid && is_pid(pid) do
        state = :rpc.call(node, :sys, :get_status, [pid])
        IO.puts("\n#{mod} status:")
        IO.inspect(state, limit: 30)
      end
    rescue _ -> :ok
    end
  end
end
