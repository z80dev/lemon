defmodule LemonCore.Testing.FileServerTap do
  @moduledoc """
  Deterministic interleaving for path-based file races in tests.

  Non-raw `:file` operations, and therefore `File.lstat/1`, `File.open/2`,
  `File.write/3`, `File.rename/2`, `File.rm/1`, `File.mkdir/1`,
  `File.read/1` and friends, are `gen_server` calls to the registered
  `:file_server_2`. `with_tap/2` registers a proxy under that name which calls
  `hook.(request)` *before* forwarding each request to the real server, so a
  test can swap a directory for a symlink at exactly one point between a
  check and a use, the way a concurrent local writer could.

  Requests are tuples such as `{:read_link_info, path, opts}`,
  `{:open, path, modes}` or `{:rename, from, to}`; `path/1` returns the first
  path argument as a string.

  The hook runs inside the proxy: it must not call `File` or `:file` (they
  would call the proxy itself). Use `swap_for_symlink/2` and `restore/1`,
  which use `:prim_file` directly, and the proxy's process dictionary for
  state. A raising hook is recorded and returned by `with_tap/2` as
  `{:hook_failed, exception}`.

  The tap is VM-global: only `async: false` tests may use it, and other
  processes' file calls pass through it unchanged while it is installed.
  Descriptor-bound I/O (`LemonCore.ConfinedFS`) does not use the file server
  and is not intercepted.
  """

  @server :file_server_2

  @doc """
  Run `fun` with `hook` installed; restores the real file server afterwards.
  Returns `fun`'s result, or `{:hook_failed, exception}` when the hook raised.
  """
  @spec with_tap((tuple() -> term()), (-> result)) :: result | {:hook_failed, Exception.t()}
        when result: term()
  def with_tap(hook, fun) when is_function(hook, 1) and is_function(fun, 0) do
    real = Process.whereis(@server) || raise "file server is not running"
    test = self()
    proxy = spawn(fn -> loop(real, hook, test) end)
    true = Process.unregister(@server)
    true = Process.register(proxy, @server)

    try do
      result = fun.()

      receive do
        {__MODULE__, :hook_failed, ^proxy, exception} -> {:hook_failed, exception}
      after
        0 -> result
      end
    after
      if Process.whereis(@server) == proxy, do: Process.unregister(@server)
      Process.register(real, @server)
      Process.exit(proxy, :kill)
    end
  end

  @doc "The first path argument of a file server request, as a string."
  @spec path(tuple()) :: String.t() | nil
  def path(request) when is_tuple(request) and tuple_size(request) >= 2 do
    case elem(request, 1) do
      name when is_binary(name) or is_list(name) -> IO.chardata_to_string(name)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def path(_request), do: nil

  @doc """
  Move the directory `dir` aside to `dir <> ".moved"` and put a symlink to
  `target` in its place (the swap a concurrent writer performs).
  """
  @spec swap_for_symlink(String.t(), String.t()) :: :ok
  def swap_for_symlink(dir, target) do
    :ok = :prim_file.rename(dir, dir <> ".moved")
    :ok = :prim_file.make_symlink(target, dir)
  end

  @doc "Undo `swap_for_symlink/2`."
  @spec restore(String.t()) :: :ok
  def restore(dir) do
    :ok = :prim_file.delete(dir)
    :ok = :prim_file.rename(dir <> ".moved", dir)
  end

  defp loop(real, hook, test) do
    receive do
      {:"$gen_call", _from, request} = message ->
        try do
          hook.(request)
        rescue
          exception -> send(test, {__MODULE__, :hook_failed, self(), exception})
        end

        send(real, message)

      message ->
        send(real, message)
    end

    loop(real, hook, test)
  end
end
