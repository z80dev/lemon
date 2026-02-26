# Test voice system components

IO.puts("Testing Voice System Components")
IO.puts("=================================")

# Test 1: Check config
IO.puts("\n1. Checking voice config...")

voice_enabled = Application.get_env(:lemon_gateway, :voice_enabled, false)
IO.puts("   voice_enabled: #{voice_enabled}")

dep_key = Application.get_env(:lemon_gateway, :deepgram_api_key)
IO.puts("   deepgram_api_key: #{if dep_key, do: "SET (#{String.length(dep_key)} chars)", else: "NOT SET"}")

el_key = Application.get_env(:lemon_gateway, :elevenlabs_api_key)
IO.puts("   elevenlabs_api_key: #{if el_key, do: "SET (#{String.length(el_key)} chars)", else: "NOT SET"}")

open_key = Application.get_env(:lemon_gateway, :openai_api_key)
IO.puts("   openai_api_key: #{if open_key, do: "SET (#{String.length(open_key)} chars)", else: "NOT SET"}")

# Test 2: Check if voice server started
IO.puts("\n2. Checking voice server...")
port = Application.get_env(:lemon_gateway, :voice_websocket_port, 4047)
IO.puts("   Configured port: #{port}")

# Check if anything is listening on port 4047
case :gen_tcp.connect(~c"localhost", 4047, [], 1000) do
  {:ok, sock} ->
    :gen_tcp.close(sock)
    IO.puts("   Port 4047: LISTENING ✓")
  {:error, reason} ->
    IO.puts("   Port 4047: NOT ACCESSIBLE (#{reason})")
end

# Test 3: Check registries and supervisors
IO.puts("\n3. Checking voice infrastructure...")

registries = [
  LemonGateway.Voice.CallRegistry,
  LemonGateway.Voice.DeepgramRegistry
]

for reg <- registries do
  case Process.whereis(reg) do
    nil -> IO.puts("   #{reg}: NOT RUNNING ✗")
    pid -> IO.puts("   #{reg}: RUNNING (pid #{:erlang.pid_to_list(pid)}) ✓")
  end
end

supervisors = [
  LemonGateway.Voice.CallSessionSupervisor,
  LemonGateway.Voice.DeepgramSupervisor
]

for sup <- supervisors do
  case Process.whereis(sup) do
    nil -> IO.puts("   #{sup}: NOT RUNNING ✗")
    pid -> IO.puts("   #{sup}: RUNNING (pid #{:erlang.pid_to_list(pid)}) ✓")
  end
end

IO.puts("\n=================================")
IO.puts("Test complete")
