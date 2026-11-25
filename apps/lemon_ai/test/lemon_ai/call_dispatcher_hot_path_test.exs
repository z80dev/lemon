defmodule LemonAi.CallDispatcherHotPathTest do
  @moduledoc """
  Model calls never make a synchronous call to a `LemonAi.CallDispatcher`
  singleton: admission uses per-provider authorities and failure summaries
  live in ETS (#696).
  """
  use ExUnit.Case, async: false

  alias LemonAi.{CallDispatcher, EventStream, ProviderRegistry}
  alias LemonAi.Types.{AssistantMessage, Context, Cost, Model, TextContent, Usage}

  @api :call_dispatcher_hot_path_test

  defmodule FakeProvider do
    @behaviour LemonAi.Provider
    alias LemonAi.EventStream
    alias LemonAi.Types.StreamOptions

    @impl true
    def api_id, do: :call_dispatcher_hot_path_test
    @impl true
    def provider_id, do: :call_dispatcher_hot_path_test

    @impl true
    def stream(_model, _context, %StreamOptions{provider_options: %{outcome: outcome}}) do
      case outcome do
        {:error, _reason} = error ->
          error

        {:complete, message} ->
          {:ok, stream} = EventStream.start_link()
          EventStream.push(stream, {:start, %{message | content: []}})
          EventStream.complete(stream, message)
          {:ok, stream}

        {:fail, message} ->
          {:ok, stream} = EventStream.start_link()
          EventStream.push(stream, {:start, %{message | content: []}})
          EventStream.error(stream, message)
          {:ok, stream}
      end
    end
  end

  setup do
    ProviderRegistry.register(@api, FakeProvider)
    provider = "hot-path-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({GenServer, :call, :_}, false, [:global])
      ProviderRegistry.unregister(@api)
    end)

    %{provider: provider}
  end

  defp message(reason) do
    %AssistantMessage{
      api: @api,
      provider: @api,
      model: "fake",
      usage: %Usage{cost: %Cost{}},
      stop_reason: if(reason, do: :error, else: :stop),
      content: if(reason, do: [], else: [%TextContent{text: "ok"}]),
      error_message: if(reason, do: LemonAi.Error.format_error(reason)),
      error_details: if(reason, do: LemonAi.Error.to_error_details(reason))
    }
  end

  defp trace_dispatcher_calls do
    # Report only GenServer.call/2,3 addressed to the dispatcher name, from any
    # process: the stream tracker runs under LemonAi.StreamTaskSupervisor.
    match_spec = [
      {[CallDispatcher, :_], [], []},
      {[CallDispatcher, :_, :_], [], []}
    ]

    :erlang.trace_pattern({GenServer, :call, :_}, match_spec, [:global])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])
  end

  defp wait_for_slot_release(provider) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      if CallDispatcher.get_active_requests(provider) == 0 do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end)
  end

  test "stream and complete never call a dispatcher singleton, including failure recording",
       %{provider: provider} do
    model = %Model{id: "fake", name: "Fake", api: @api, provider: provider}
    context = Context.new()
    success = message(nil)
    failed = message({:http_error, 503, "Service Unavailable"})
    trace_dispatcher_calls()

    assert {:ok, stream} =
             LemonAi.stream(model, context, %{provider_options: %{outcome: {:complete, success}}})

    assert {:ok, ^success} = EventStream.result(stream)

    assert {:ok, ^success} =
             LemonAi.complete(model, context, %{
               provider_options: %{outcome: {:complete, success}}
             })

    assert {:ok, stream} =
             LemonAi.stream(model, context, %{provider_options: %{outcome: {:fail, failed}}})

    assert {:error, _} = EventStream.result(stream)

    assert {:error, :timeout} =
             LemonAi.stream(model, context, %{provider_options: %{outcome: {:error, :timeout}}})

    # Stream trackers record terminal results after the caller sees them.
    assert :ok = wait_for_slot_release(provider)
    :erlang.trace(:all, false, [:call])

    refute_received {:trace, _pid, :call, {GenServer, :call, _args}}
    assert CallDispatcher.last_error(provider)["message"] =~ "temporarily unavailable"
  end
end
