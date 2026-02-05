defmodule LemonGateway.Web.SocketHandler do
  @behaviour :cowboy_websocket

  alias LemonGateway.Types.{Job, ChatScope, ResumeToken}
  alias LemonGateway.{Event, Store, EngineRegistry}

  require Logger

  # Connection state
  defstruct [:scope, :timer_ref]

  @ping_interval 30_000

  def init(req, state) do
    # Extract scope from query params or headers if needed
    # For now, we assume a single session per socket connection for simplicity
    # Ideally, we should perform auth here.
    
    # We'll use a random UUID for the "chat_id" to treat each browser tab as a unique session
    # unless a session_id is provided in the query string.
    
    qs = :cowboy_req.parse_qs(req)
    session_id = 
      case List.keyfind(qs, "session_id", 0) do
        {_, val} -> val
        nil -> UUID.uuid4()
      end
      
    scope = %ChatScope{
      transport: :web,
      chat_id: session_id,
      topic_id: nil 
    }

    {:cowboy_websocket, req, %__MODULE__{scope: scope}}
  end

  def websocket_init(state) do
    Logger.info("Web client connected: #{inspect(state.scope)}")
    # Subscribe to gateway events for this scope?
    # Actually, Gateway pushes events to the transport via return values or callbacks.
    # But since we are submitting jobs, we need a way to route responses back to this socket.
    
    # In LemonGateway, the job submission includes a notify_pid. 
    # We will use self() as the notify_pid, so the Gateway (or rather the Runner) 
    # sends messages back to this process.
    
    timer_ref = Process.send_after(self(), :ping, @ping_interval)
    
    # Send initial status
    send_json(%{type: "status", status: "connected", session_id: state.scope.chat_id})
    
    {:ok, %{state | timer_ref: timer_ref}}
  end

  def websocket_handle({:text, json}, state) do
    case Jason.decode(json) do
      {:ok, %{"type" => "ping"}} ->
        {:reply, {:text, Jason.encode!(%{type: "pong"})}, state}
        
      {:ok, %{"type" => "prompt", "text" => text} = msg} ->
        handle_prompt(text, msg, state)
        {:ok, state}
        
      {:ok, %{"type" => "steer", "text" => text}} ->
        # TODO: Implement steering if needed
        {:ok, state}
        
      {:error, _} ->
        {:reply, {:text, Jason.encode!(%{type: "error", message: "Invalid JSON"})}, state}
        
      _ ->
        {:ok, state}
    end
  end

  def websocket_handle(_frame, state) do
    {:ok, state}
  end

  def websocket_info(:ping, state) do
    Process.send_after(self(), :ping, @ping_interval)
    {:reply, {:text, Jason.encode!(%{type: "ping"})}, state}
  end

  # Handle messages coming from the Gateway/Engine
  
  # 1. Progress updates
  def websocket_info({:gateway_progress, msg}, state) do
    send_json(%{type: "progress", message: msg})
    {:ok, state}
  end

  # 2. Engine events (if we subscribed or if they are forwarded)
  # The standard LemonGateway flow sends events to the "sink_pid" which is usually the Run process.
  # But the Run process sends rendered text back to the Transport via the notify_pid (which is us).
  
  # Wait, LemonGateway.Telegram.Transport sends a job with `notify_pid: self()`.
  # The `Run` process does NOT send messages to `notify_pid` automatically.
  # The `Run` process writes to `Store`.
  # `LemonGateway.Telegram.Transport` does NOT implement `handle_info` for job completion?
  # Let's check `LemonGateway.submit`.
  
  # Checking `LemonGateway.submit/1`: It calls `Scheduler.submit/1`.
  # `Scheduler` assigns a slot and starts `ThreadWorker`.
  # `ThreadWorker` starts `Run`.
  # `Run` executes the engine.
  
  # The `Run` module defines how output is handled.
  # It seems `Run` uses `Store` to save events.
  # It assumes there is a "Renderer" that might stream chunks?
  
  # Let's look at how we get output back.
  # In `LemonGateway.Telegram.Transport`, there is no code to receive messages back from the engine?
  # Ah, `LemonGateway.Telegram.Transport` only handles INCOMING messages.
  # It relies on `LemonGateway.Telegram.Outbox` or similar? 
  # Wait, the architecture diagram says: 
  # "Run selects the appropriate engine, starts the AI run, streams events back"
  
  # Let's check `LemonGateway.Run` to see where it sends events.
  
  # NOTE: I'll finish this file content after verifying the return path in the next step.
  # For now, I will implement a basic version.

  def websocket_info({:lemon_gateway_run_completed, job, completed}, state) do
    # Run completed event
    send_json(%{
      type: "event",
      event: %{
        type: "run_completed",
        ok: completed.ok,
        error: completed.error,
        answer: completed.answer
      }
    })
    {:ok, state}
  end
  
  # Handle delta events (if we subscribe to the bus or receive them somehow)
  # But wait, LemonGateway.Run emits to the BUS. 
  # It does NOT send deltas to notify_pid.
  # It ONLY sends `{:lemon_gateway_run_completed, job, completed}` to notify_pid.
  
  # So for streaming, we MUST subscribe to the LemonCore.Bus topic "run:<run_id>"
  # OR we need to poll, OR we rely on a different mechanism.
  
  # Let's use the notify_pid event to get the run_id, then subscribe?
  # No, notify_pid gets the COMPLETED event. That's too late for streaming.
  
  # We need to know the run_id BEFORE it completes.
  # LemonGateway.submit returns :ok (async).
  
  # However, `LemonGateway.Scheduler` manages the run.
  # There is no direct callback for "run started" to the submitter.
  
  # But we can pass a "progress_msg_id" in meta. 
  # LemonGateway.Run calls `LemonGateway.Store.put_progress_mapping(scope, progress_msg_id, run_pid)`
  # But that is for cancellation (cancel by progress msg id).
  
  # If we want streaming, we should probably use `LemonCore.Bus` if available.
  # The `Run` module does `emit_to_bus(run_id, :delta, ...)`
  
  # The problem: We don't know the `run_id` when we submit the job.
  # The `run_id` is generated inside `LemonGateway.Run.init` or `job.run_id`.
  
  # AHA! We can generate the `run_id` OURSELVES and put it in the job!
  # `LemonGateway.Run` uses `job.run_id || generate_run_id()`.
  
  # So, the plan:
  # 1. Generate a UUID for `run_id`.
  # 2. Subscribe to `run:<run_id>` on `LemonCore.Bus`.
  # 3. Submit the job with that `run_id`.
  # 4. Receive bus events and forward to websocket.
  
  defp handle_prompt(text, _msg, state) do
    run_id = "run_#{UUID.uuid4()}"
    
    # Subscribe to the run topic on the bus
    if Code.ensure_loaded?(LemonCore.Bus) do
      LemonCore.Bus.subscribe("run:#{run_id}")
    end

    # Create and submit a Job
    job = %Job{
      scope: state.scope,
      user_msg_id: UUID.uuid4(), 
      run_id: run_id, # Pre-assign run_id so we can listen
      text: text,
      resume: nil, 
      engine_hint: nil,
      queue_mode: :collect,
      meta: %{
        notify_pid: self(),
        transport_pid: self()
      }
    }
    
    LemonGateway.submit(job)
  end
  
  # Handle Bus events
  def websocket_info({:lemon_event, _topic, event}, state) do
    # event is a LemonCore.Event struct or tuple
    payload = 
      case event do
        %{payload: p} -> p
        {_type, p} -> p
        _ -> event
      end
      
    # Forward relevant events to client
    # The client expects specific JSON structure. We might need to map it.
    # For now, let's just dump the event type and payload.
    
    # Check if it is a delta
    case event do
      %{type: :delta, payload: delta} ->
         send_json(%{
           type: "event", 
           event: %{
             type: "delta", 
             text: delta.text, 
             seq: delta.seq
           }
         })
         
      %{type: :run_completed, payload: %{completed: completed}} ->
         send_json(%{
            type: "event",
            event: %{
              type: "run_completed",
              ok: completed.ok,
              answer: completed.answer
            }
         })
         
      %{type: :run_started} ->
          send_json(%{type: "event", event: %{type: "run_started"}})
          
      _ -> 
          # Ignore other events or debug log
          Logger.debug("Ignored bus event: #{inspect(event)}")
    end
    
    {:ok, state}
  end

  # Fallback for the notify_pid message (which we might still get)
  def websocket_info({:lemon_gateway_run_completed, _job, _completed}, state) do
    # We already handle this via bus subscription, so we can ignore this duplicate
    # OR we use this as a backup.
    {:ok, state}
  end
  
  defp send_json(data) do
    # This is a helper, but in cowboy_websocket we return {:reply, frame, state}
    # So we can't just call this. 
    # We'll use self-messages for async sends if needed, or return values for sync.
    # But wait, send_json/1 isn't really usable here directly as a side effect.
    # We should return the frame.
    Process.send(self(), {:send_json, data}, [])
  end
  
  # Helper to handle the self-message for sending JSON
  def websocket_info({:send_json, data}, state) do
     {:reply, {:text, Jason.encode!(data)}, state}
  end
end
