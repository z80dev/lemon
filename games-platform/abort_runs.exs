# Abort all stuck runs

node = :"lemon_gateway@chico"

if Node.ping(node) == :pong do
  runs = [
    "run_ca97fb31-c4fc-413d-8ce8-7f88c3272299",
    "run_d8f6ee3b-1e33-469a-9e97-a1ef7eb8dcba", 
    "run_b1ac7462-b923-4f7e-b658-1f99b00f8f78",
    "run_950610dd-468b-43b9-b119-25642c5aaba7"
  ]
  
  IO.puts("=== ABORTING STUCK RUNS ===\n")
  
  for run_id <- runs do
    IO.puts("Aborting #{run_id}...")
    try do
      # Try to send abort signal via the run process
      case :rpc.call(node, Registry, :lookup, [LemonRouter.RunRegistry, run_id]) do
        [{pid, _}] ->
          # Send abort to the run process
          result = :rpc.call(node, GenServer, :call, [pid, :abort, 5000])
          IO.puts("  Result: #{inspect(result)}")
        [] ->
          IO.puts("  Not found in registry")
      end
    rescue e -> 
      IO.puts("  Error: #{inspect(e)}")
    end
  end
  
  # Also try to stop the run processes directly
  IO.puts("\n=== STOPPING RUN PROCESSES ===\n")
  
  try do
    children = :rpc.call(node, DynamicSupervisor, :which_children, [LemonRouter.RunSupervisor])
    IO.puts("Found #{length(children)} run processes")
    
    for {_, pid, :worker, _} <- children do
      IO.puts("Stopping #{inspect(pid)}...")
      try do
        :rpc.call(node, DynamicSupervisor, :terminate_child, [LemonRouter.RunSupervisor, pid])
        IO.puts("  Terminated")
      rescue e -> 
        IO.puts("  Error: #{inspect(e)}")
      end
    end
  rescue e -> 
    IO.puts("Error getting children: #{inspect(e)}")
  end
  
  # Wait a moment and check if they're gone
  IO.puts("\n=== VERIFYING CLEANUP ===\n")
  :timer.sleep(1000)
  
  try do
    remaining = :rpc.call(node, Registry, :select, [LemonRouter.RunRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]])
    IO.puts("Remaining runs: #{length(remaining)}")
    IO.inspect(remaining)
  rescue e -> 
    IO.puts("Error checking registry: #{inspect(e)}")
  end
end
