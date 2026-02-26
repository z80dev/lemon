# Check active runs in detail

node = :"lemon_gateway@chico"

if Node.ping(node) == :pong do
  IO.puts("=== ACTIVE RUNS DETAIL ===\n")
  
  runs = [
    "run_ca97fb31-c4fc-413d-8ce8-7f88c3272299",
    "run_d8f6ee3b-1e33-469a-9e97-a1ef7eb8dcba", 
    "run_b1ac7462-b923-4f7e-b658-1f99b00f8f78",
    "run_950610dd-468b-43b9-b119-25642c5aaba7"
  ]
  
  for run_id <- runs do
    IO.puts("--- #{run_id} ---")
    try do
      # Look up the run process
      case :rpc.call(node, Registry, :lookup, [LemonRouter.RunRegistry, run_id]) do
        [{pid, _}] ->
          IO.puts("  PID: #{inspect(pid)}")
          
          # Get run process state
          state = :rpc.call(node, :sys, :get_state, [pid])
          IO.puts("  Status: #{state.status}")
          IO.puts("  Agent ID: #{state.agent_id}")
          IO.puts("  Session Key: #{state.session_key}")
          IO.puts("  Message ID: #{state.message_id}")
          IO.puts("  Parent Run ID: #{inspect(state.parent_run_id)}")
          IO.puts("  Started At: #{state.started_at}")
          IO.inspect(state.error, label: "  Error")
          
        [] ->
          IO.puts("  NOT FOUND in registry")
      end
    rescue e -> 
      IO.puts("  ERROR: #{inspect(e)}")
    end
    IO.puts("")
  end
  
  # Check the RunProcess processes directly
  IO.puts("\n=== RUN PROCESS DETAILS ===\n")
  
  try do
    children = :rpc.call(node, DynamicSupervisor, :which_children, [LemonRouter.RunSupervisor])
    for {_, pid, :worker, _} <- children do
      IO.puts("Process #{inspect(pid)}:")
      info = :rpc.call(node, Process, :info, [pid, [:current_function, :status, :message_queue_len]])
      IO.inspect(info)
      
      # Try to get state
      try do
        state = :rpc.call(node, :sys, :get_state, [pid])
        IO.puts("  Run ID: #{state.run_id}")
        IO.puts("  Status: #{state.status}")
        if state.status == :executing do
          IO.puts("  ⚠️  STILL EXECUTING - may be stuck!")
        end
      rescue _ -> :ok
      end
      IO.puts("")
    end
  rescue e -> IO.puts("Error: #{inspect(e)}")
  end
  
  # Check session details
  IO.puts("\n=== SESSION DETAILS ===\n")
  session_key = "agent:default:telegram:default:group:-1003842984060:thread:2709"
  try do
    case :rpc.call(node, Registry, :lookup, [LemonRouter.SessionRegistry, session_key]) do
      [{pid, _}] ->
        IO.puts("Session PID: #{inspect(pid)}")
        state = :rpc.call(node, :sys, :get_state, [pid])
        IO.inspect(state, limit: 50, printable_limit: 3000)
      [] ->
        IO.puts("Session not found in registry")
    end
  rescue e -> IO.puts("Session error: #{inspect(e)}")
  end
end
