defmodule CodingAgent.TestHelpers.PermissionHelpers do
  @moduledoc """
  OS-agnostic permission testing helpers.

  Provides `with_unreadable/2`, `with_unwritable_dir/2`, and
  `with_unwritable_file/2` which apply `chmod`, run the callback, and
  restore permissions — but first verify that the OS actually enforces
  the restriction. If permissions are not enforced (e.g., running as
  root), the test is skipped with a descriptive message rather than
  producing a false positive.
  """

  import ExUnit.Assertions

  @doc """
  Makes `path` unreadable (0o000), runs `fun`, then restores permissions.

  Skips the test if the OS does not enforce the permission (e.g. root).
  """
  def with_unreadable(path, fun) when is_binary(path) and is_function(fun, 0) do
    File.chmod!(path, 0o000)

    if can_read_despite_chmod?(path) do
      File.chmod!(path, 0o644)
      flunk("Skipping: OS does not enforce read permission (running as root?)")
    end

    try do
      fun.()
    after
      File.chmod!(path, 0o644)
    end
  end

  @doc """
  Makes the directory `dir` unwritable (0o555), runs `fun`, then restores.

  Skips the test if the OS does not enforce the permission.
  """
  def with_unwritable_dir(dir, fun) when is_binary(dir) and is_function(fun, 0) do
    File.chmod!(dir, 0o555)

    probe = Path.join(dir, ".permission_probe_#{System.unique_integer([:positive])}")

    if can_write_despite_chmod?(probe) do
      File.chmod!(dir, 0o755)
      flunk("Skipping: OS does not enforce directory write permission (running as root?)")
    end

    try do
      fun.()
    after
      File.chmod!(dir, 0o755)
    end
  end

  @doc """
  Makes `path` read-only (0o444), runs `fun`, then restores.

  Skips the test if the OS does not enforce the permission.
  """
  def with_readonly_file(path, fun) when is_binary(path) and is_function(fun, 0) do
    File.chmod!(path, 0o444)

    if can_overwrite_despite_chmod?(path) do
      File.chmod!(path, 0o644)
      flunk("Skipping: OS does not enforce file write permission (running as root?)")
    end

    try do
      fun.()
    after
      File.chmod!(path, 0o644)
    end
  end

  # --------------------------------------------------------------------------
  # Probes
  # --------------------------------------------------------------------------

  defp can_read_despite_chmod?(path) do
    case File.read(path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp can_write_despite_chmod?(probe_path) do
    case File.write(probe_path, "probe") do
      :ok ->
        File.rm(probe_path)
        true

      {:error, _} ->
        false
    end
  end

  defp can_overwrite_despite_chmod?(path) do
    original = File.read!(path)

    case File.write(path, "probe") do
      :ok ->
        # Restore original content
        File.chmod!(path, 0o644)
        File.write!(path, original)
        true

      {:error, _} ->
        false
    end
  end
end
