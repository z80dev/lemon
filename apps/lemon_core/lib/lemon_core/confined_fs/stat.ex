defmodule LemonCore.ConfinedFS.Stat do
  @moduledoc "`lstat` result from `LemonCore.ConfinedFS`; `mode` holds permission bits only."

  @enforce_keys [:type, :mode, :size, :dev, :inode, :nlink, :uid, :mtime]
  defstruct [:type, :mode, :size, :dev, :inode, :nlink, :uid, :mtime, mtime_nsec: 0]

  @type t :: %__MODULE__{
          type: :regular | :directory | :symlink | :other,
          mode: non_neg_integer(),
          size: non_neg_integer(),
          dev: non_neg_integer(),
          inode: non_neg_integer(),
          nlink: non_neg_integer(),
          uid: non_neg_integer(),
          mtime: integer(),
          mtime_nsec: non_neg_integer()
        }

  @doc false
  def decode(
        <<type, mode::32, size::64, dev::64, inode::64, nlink::32, uid::32, mtime::64-signed,
          mtime_nsec::32>>
      ) do
    %__MODULE__{
      type: decode_type(type),
      mode: mode,
      size: size,
      dev: dev,
      inode: inode,
      nlink: nlink,
      uid: uid,
      mtime: mtime,
      mtime_nsec: mtime_nsec
    }
  end

  @doc "Whether two stats name the same filesystem object (device and inode)."
  @spec same_object?(t(), t()) :: boolean()
  def same_object?(%__MODULE__{dev: dev, inode: inode}, %__MODULE__{dev: dev, inode: inode}),
    do: true

  def same_object?(_a, _b), do: false

  defp decode_type(1), do: :regular
  defp decode_type(2), do: :directory
  defp decode_type(3), do: :symlink
  defp decode_type(_), do: :other
end
