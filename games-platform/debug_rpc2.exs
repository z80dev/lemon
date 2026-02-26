# RPC debug inspection script - deeper dive

node = :"lemon_gateway@chico"

if Node.ping(node) == :pong do
  IO.puts("=== LEMON ROUTER STATE ===")
  
  # Check RunOrchestrator
  try do
    pid = :rpc.call(node, Process, :whereis, [LemonRouter.RunOrchestrator])
    if pid do
      IO.puts("\nRunOrchestrator: #{inspect(pid)}")
      state = :rpc.call(node, :sys, :get_state, [pid])
      IO.inspect(state, limit: 50, printable_limit: 2000)
    end
  rescue e -> IO.puts("RunOrchestrator error: #{inspect(e)}")
  end
  
  # Check RunSupervisor children
  try do
    pid = :rpc.call(node, Process, :whereis, [LemonRouter.RunSupervisor])
    if pid do
      IO.puts("\n\nRunSupervisor children:")
      children = :rpc.call(node, DynamicSupervisor, :which_children, [pid])
      IO.inspect(children, limit: 50)
    end
  rescue e -> IO.puts("RunSupervisor error: #{inspect(e)}")
  end
  
  # Check CoalescerSupervisor
  try do
    pid = :rpc.call(node, Process, :whereis, [LemonRouter.CoalescerSupervisor])
    if pid do
      IO.puts("\n\nCoalescerSupervisor children:")
      children = :rpc.call(node, DynamicSupervisor, :which_children, [pid])
      IO.inspect(children, limit: 50)
    end
  rescue e -> IO.puts("CoalescerSupervisor error: #{inspect(e)}")
  end
  
  # Check SessionRegistry
  IO.puts("\n\n=== SESSION REGISTRY ===")
  try do
    sessions = :rpc.call(node, Registry, :select, [LemonRouter.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]])
    IO.puts("Active sessions: #{length(sessions)}")
    sessions |> Enum.take(20) |> IO.inspect(limit: 50)
  rescue e -> IO.puts("SessionRegistry error: #{inspect(e)}")
  end
  
  # Check RunRegistry
  IO.puts("\n=== RUN REGISTRY ===")
  try do
    runs = :rpc.call(node, Registry, :select, [LemonRouter.RunRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]])
    IO.puts("Active runs: #{length(runs)}")
    runs |> Enum.take(20) |> IO.inspect(limit: 50)
  rescue e -> IO.puts("RunRegistry error: #{inspect(e)}")
  end
  
  # Check CodingAgent sessions
  IO.puts("\n=== CODING AGENT SESSIONS ===")
  try do
    ca_sessions = :rpc.call(node, Registry, :select, [CodingAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]])
    IO.puts("Active coding agent sessions: #{length(ca_sessions)}")
    ca_sessions |> Enum.take(20) |> IO.inspect(limit: 50)
  rescue e -> IO.puts("CodingAgent SessionRegistry error: #{inspect(e)}")
  end
  
  # Check AgentCore agents
  IO.puts("\n=== AGENT CORE AGENTS ===")
  try do
    agents = :rpc.call(node, Registry, :select, [AgentCore.AgentRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]])
    IO.puts("Active agents: #{length(agents)}")
    agents |> Enum.take(20) |> IO.inspect(limit: 50)
  rescue e -> IO.puts("AgentCore AgentRegistry error: #{inspect(e)}")
  end
  
  # Check ProcessManager
  IO.puts("\n=== CODING AGENT PROCESS MANAGER ===")
  try do
    pid = :rpc.call(node, Process, :whereis, [CodingAgent.ProcessManager])
    if pid do
      state = :rpc.call(node, :sys, :get_state, [pid])
      IO.inspect(state, limit: 50, printable_limit: 2000)
    end
  rescue e -> IO.puts("ProcessManager error: #{inspect(e)}")
  end
  
  # Check LaneQueue
  IO.puts("\n=== LANE QUEUE ===")
  try do
    pid = :rpc.call(node, Process, :whereis, [CodingAgent.LaneQueue])
    if pid do
      state = :rpc.call(node, :sys, :get_state, [pid])
      IO.inspect(state, limit: 50, printable_limit: 2000)
    end
  rescue e -> IO.puts("LaneQueue error: #{inspect(e)}")
  end
  
  # Check Outbox
  IO.puts("\n=== CHANNELS OUTBOX ===")
  try do
    pid = :rpc.call(node, Process, :whereis, [LemonChannels.Outbox])
    if pid do
      state = :rpc.call(node, :sys, :get_state, [pid])
      IO.inspect(state, limit: 50, printable_limit: 2000)
    end
  rescue e -> IO.puts("Outbox error: #{inspect(e)}")
  end
  
  # Check Store
  IO.puts("\n=== LEMON CORE STORE ===")
  try do
    pid = :rpc.call(node, Process, :whereis, [LemonCore.Store])
    if pid do
      info = :rpc.call(node, Process, :info, [pid])
      IO.inspect(info[:dictionary], limit: 30)
    end
  rescue e -> IO.puts("Store error: #{inspect(e)}")
  end
end
