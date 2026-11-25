defmodule LemonGateway.Voice.DeepgramCall do
  @moduledoc false

  alias LemonGateway.Voice.{CallSession, Config, DeepgramRegistry, DeepgramSupervisor}
  alias LemonMedia.Providers.DeepgramStream

  def child_spec(opts) do
    call_sid = Keyword.fetch!(opts, :call_sid)
    session_pid = Keyword.fetch!(opts, :session_pid)

    DeepgramStream.child_spec(
      api_key: Config.deepgram_api_key(),
      name: {:via, Registry, {DeepgramRegistry, call_sid}},
      on_connect: &CallSession.register_deepgram_ws(session_pid, &1),
      on_transcript: &CallSession.handle_transcript(session_pid, &1)
    )
  end

  def stop_for_call(call_sid) when is_binary(call_sid) do
    if Process.whereis(DeepgramRegistry) do
      case Registry.lookup(DeepgramRegistry, call_sid) do
        [{pid, _}] -> stop(pid)
        [] -> :ok
      end
    else
      :ok
    end
  end

  def stop(pid) when is_pid(pid) do
    case Process.whereis(DeepgramSupervisor) do
      nil -> :ok
      sup -> _ = DynamicSupervisor.terminate_child(sup, pid)
    end

    :ok
  end

  def stop(_), do: :ok
end
