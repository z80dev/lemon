defmodule CodingAgent.Session.Ownership do
  @moduledoc false

  alias CodingAgent.{MutationLock, SessionManager}

  # Stopped mutations decide and write under this file admission. A starting
  # session holds it only long enough to publish itself as the live owner; it
  # loads the journal and runs slow initialization after releasing admission,
  # so later mutations are routed to (and queue behind) that owner.
  def with_file(path, fun) do
    CodingAgent.SessionMaintenance.with_root_lock(fn ->
      MutationLock.with_lock({:native_session, Path.expand(path)}, fun)
    end)
  end

  @doc """
  Publish the calling process as the live owner of the journal `opts` select.

  Returns `{:ok, opts, path}` with a generated `:session_id` when neither a
  file nor an ID was given, `{:error, {:already_started, pid}}` when another
  process owns the journal, or the admission lock error.
  """
  def admit(opts) do
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
          :ok = publish(path)
          {:ok, opts, path}

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
    CodingAgent.SessionMaintenance.with_root_lock(fn ->
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
    end)
  end

  # Kernel-owned registration survives coding_agent's one_for_one restarts.
  # Include node identity: equal paths on remote nodes are different journals.
  defp owner_name(path), do: {__MODULE__, node(), Path.expand(path)}
end
