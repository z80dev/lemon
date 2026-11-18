defmodule LemonSkills.TestSupport.FakeSsh do
  @moduledoc false

  # Puts an `ssh` on PATH that serves the requested repository with the local
  # `git upload-pack`, so SSH clones through `LemonSkills.GitRemote` run
  # offline against a literal public address. PATH is global: use only from
  # `async: false` tests.

  import ExUnit.Callbacks, only: [on_exit: 1]

  @address "93.184.216.34"

  @spec install!(Path.t()) :: :ok
  def install!(tmp_dir) do
    bin = Path.join(tmp_dir, "fake-ssh-bin")
    File.mkdir_p!(bin)
    ssh = Path.join(bin, "ssh")
    File.write!(ssh, "#!/bin/sh\nfor last; do :; done\nexec sh -c \"git ${last#git-}\"\n")
    File.chmod!(ssh, 0o755)

    previous = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous)
    on_exit(fn -> System.put_env("PATH", previous) end)
    :ok
  end

  @doc "An SSH clone URL for the local repository `repo`."
  @spec url(Path.t()) :: String.t()
  def url(repo), do: "ssh://git@#{@address}#{Path.expand(repo)}"
end
