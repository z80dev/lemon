defmodule CodingAgent.CwdIdentity do
  @moduledoc """
  Binds a session to the working directory object a trusted submitter checked.

  A run request may carry `meta.cwd_identity` (`%{"major", "minor", "inode"}`,
  e.g. from kanban workers). The session runner verifies it immediately before
  the session starts, and `CodingAgent.ToolRegistry` verifies it again before
  every tool call: when the path no longer resolves to that directory object
  (replaced, renamed, swapped for a symlink), the session does not start or the
  tool call is refused.

  Remaining window: a replacement made between one of those checks and the
  filesystem access it guards (within a single tool call), or below the working
  directory (a subdirectory swapped for a symlink), is not detected. For kanban
  workers the working directory is a controller-created worktree under the
  Lemon-owned `~/.lemon/kanban/worktrees` base, so either requires write access
  to that base or to the worktree itself.
  """

  @doc "`:ok` when `cwd` is the directory object `identity` names (or no binding)."
  @spec verify(term(), term()) :: :ok | {:error, :cwd_identity_mismatch}
  def verify(_cwd, nil), do: :ok

  def verify(cwd, %{"major" => major, "minor" => minor, "inode" => inode})
      when is_binary(cwd) do
    case File.stat(cwd) do
      {:ok,
       %File.Stat{type: :directory, major_device: ^major, minor_device: ^minor, inode: ^inode}} ->
        :ok

      _ ->
        {:error, :cwd_identity_mismatch}
    end
  end

  def verify(_cwd, _identity), do: {:error, :cwd_identity_mismatch}
end
