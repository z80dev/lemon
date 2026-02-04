# Debug script for Telegram message flow
IO.puts("\n=== TELEGRAM DEBUG ===\n")

# 1. Check if Telegram transport is running
IO.puts("1. Checking Telegram Transport process...")
case Process.whereis(LemonChannels.Adapters.Telegram.Transport) do
  nil -> IO.puts("   ❌ Telegram Transport NOT RUNNING")
  pid -> IO.puts("   ✅ Telegram Transport running: #{inspect(pid)}")
end

# 2. Check Telegram Supervisor
IO.puts("\n2. Checking Telegram Supervisor...")
case Process.whereis(LemonChannels.Adapters.Telegram.Supervisor) do
  nil -> IO.puts("   ❌ Telegram Supervisor NOT RUNNING")
  pid ->
    IO.puts("   ✅ Telegram Supervisor running: #{inspect(pid)}")
    children = Supervisor.which_children(pid)
    IO.puts("   Children: #{inspect(children)}")
end

# 3. Check Registry for Telegram plugin
IO.puts("\n3. Checking Plugin Registry...")
try do
  plugins = LemonChannels.Registry.list_plugins()
  IO.puts("   Registered plugins: #{inspect(plugins)}")
rescue
  e -> IO.puts("   Error checking registry: #{inspect(e)}")
end

# 4. Check Outbox
IO.puts("\n4. Checking Outbox...")
case Process.whereis(LemonChannels.Outbox) do
  nil -> IO.puts("   ❌ Outbox NOT RUNNING")
  pid -> IO.puts("   ✅ Outbox running: #{inspect(pid)}")
end

# 5. Check RunOrchestrator/DynamicSupervisor
IO.puts("\n5. Checking Run infrastructure...")
case Process.whereis(LemonRouter.RunSupervisor) do
  nil -> IO.puts("   ❌ RunSupervisor NOT RUNNING")
  pid ->
    IO.puts("   ✅ RunSupervisor running: #{inspect(pid)}")
    children = DynamicSupervisor.which_children(pid)
    IO.puts("   Active runs: #{length(children)}")
end

# 6. Check StreamCoalescer registry
IO.puts("\n6. Checking StreamCoalescer...")
case Process.whereis(LemonRouter.StreamCoalescer.Registry) do
  nil -> IO.puts("   ❌ StreamCoalescer Registry NOT RUNNING")
  pid -> IO.puts("   ✅ StreamCoalescer Registry running: #{inspect(pid)}")
end

# 7. Check EventBridge
IO.puts("\n7. Checking EventBridge...")
case Process.whereis(LemonControlPlane.EventBridge) do
  nil -> IO.puts("   ❌ EventBridge NOT RUNNING")
  pid -> IO.puts("   ✅ EventBridge running: #{inspect(pid)}")
end

# 8. Check LemonGateway Store for agent config
IO.puts("\n8. Checking LemonGateway Store...")
case Process.whereis(LemonGateway.Store) do
  nil -> IO.puts("   ❌ LemonGateway.Store NOT RUNNING")
  pid ->
    IO.puts("   ✅ LemonGateway.Store running: #{inspect(pid)}")
    # Try to list stored items
    try do
      agents = LemonGateway.Store.list(:agents)
      IO.puts("   Stored agents: #{inspect(Map.keys(agents))}")
    rescue
      e -> IO.puts("   Could not list agents: #{inspect(e)}")
    end
end

# 9. Check for any ETS tables
IO.puts("\n9. Checking ETS tables...")
tables = :ets.all() |> Enum.filter(fn t ->
  name = :ets.info(t, :name)
  name_str = to_string(name)
  String.contains?(name_str, "telegram") or
  String.contains?(name_str, "Telegram") or
  String.contains?(name_str, "lemon") or
  String.contains?(name_str, "Lemon")
end)
IO.puts("   Relevant ETS tables: #{inspect(tables)}")

IO.puts("\n=== END DEBUG ===\n")
