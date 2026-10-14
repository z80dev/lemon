defmodule CodingAgent.Session.Ownership do
  @moduledoc false

  alias CodingAgent.{MutationLock, SessionManager}

  # Startup holds admission from before loading the journal until its live owner
  # is published. Stopped mutations decide and write under this same admission.
  def with_file(path, fun) do
    MutationLock.with_lock({:native_session, Path.expand(path)}, fun)
  end

  def initialize(opts, fun) do
    {opts, path} =
      case Keyword.get(opts, :session_file) do
        nil ->
          id = Keyword.get(opts, :session_id) || LemonCore.Id.uuid()
          cwd = Keyword.fetch!(opts, :cwd)
          {Keyword.put(opts, :session_id, id), SessionManager.session_file_path(cwd, id)}

        path ->
          {opts, path}
      end

    with_file(path, fn ->
      case owner(path) do
        nil ->
          case fun.(opts) do
            {:ok, state} = result ->
              :ok = publish(state.session_file)
              result

            result ->
              result
          end

        pid ->
          # An admission refusal is not a crashing init. OTP returns this error
          # to start_link's caller while terminating the rejected child normally.
          {:error, {:already_started, pid}}
      end
    end)
  end

  def owner(path) do
    name = owner_name(path)

    case :global.whereis_name(name) do
      :undefined ->
        nil

      pid ->
        if Process.alive?(pid) do
          pid
        else
          :global.unregister_name(name)
          nil
        end
    end
  end

  # Called by the owning session while holding this file's admission.
  def publish(path) do
    :yes = :global.register_name(owner_name(path), self())
    :ok
  end

  def release(path), do: :global.unregister_name(owner_name(path))

  def transfer(old_path, new_path, fun) do
    keys = Enum.map([old_path, new_path], &{:native_session, Path.expand(&1)})

    MutationLock.with_locks(keys, fn ->
      nil = owner(new_path)
      result = fun.()

      # global allows one name per process. Keep both journals admitted while
      # moving the registration, so neither can be mistaken for a stopped file.
      release(old_path)
      :ok = publish(new_path)
      result
    end)
  end

  # Kernel-owned registration survives coding_agent's one_for_one restarts.
  # Include node identity: equal paths on remote nodes are different journals.
  defp owner_name(path), do: {__MODULE__, node(), Path.expand(path)}
end
