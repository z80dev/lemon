defmodule LemonAi.Auth.OmpTokenTest do
  use ExUnit.Case, async: false

  alias LemonAi.Auth.OmpToken

  setup do
    dir = Path.join(System.tmp_dir!(), "omp_token_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: Path.join(dir, "fake omp")}
  end

  test "discovers PATH before the home fallback and honors an explicit missing path", %{dir: dir} do
    original = Map.new(["HOME", "PATH"], &{&1, System.get_env(&1)})
    home_bin = Path.join(dir, ".bun/bin")
    path_bin = Path.join(dir, "bin")
    File.mkdir_p!(home_bin)
    File.mkdir_p!(path_bin)
    home_omp = Path.join(home_bin, "omp")
    path_omp = Path.join(path_bin, "omp")
    script(home_omp, "exit 0")
    script(path_omp, "exit 0")

    try do
      System.put_env("HOME", dir)
      System.put_env("PATH", path_bin)
      assert {:ok, ^path_omp} = OmpToken.discover()
      File.rm!(path_omp)
      assert {:ok, ^home_omp} = OmpToken.discover()
      assert {:error, :omp_not_found} = OmpToken.discover(Path.join(dir, "missing"))
    after
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  test "executes argv without a shell, closes stdin and shares fresh JWTs across processes", %{
    path: path,
    dir: dir
  } do
    token = jwt(3600)
    count = Path.join(dir, "calls")

    script(path, """
    test "$#" = 2 && test "$1" = token && test "$2" = kimi-code || exit 9
    if read -r input; then exit 8; fi
    printf x >> '#{count}'
    printf '%s\\n' '#{token}'
    """)

    assert {:ok, ^token} = OmpToken.resolve(path)
    assert {:ok, ^token} = Task.async(fn -> OmpToken.resolve(path) end) |> Task.await()
    assert File.read!(count) == "x"
  end

  test "selects the last JWT line despite stderr warnings and trailing notices", %{path: path} do
    earlier = jwt(1800)
    token = jwt(3600)

    script(path, """
    printf '%s\\n' '#{earlier}'
    printf 'warning: account metadata unavailable\\n' >&2
    printf '%s\\n' '#{token}'
    printf '\\nnotice: token retrieval complete\\n' >&2
    """)

    assert {:ok, ^token} = OmpToken.resolve(path)
  end

  test "expired JWTs are rejected and refetched instead of cached", %{path: path} do
    script(path, "printf '%s' '#{jwt(-60)}'")
    assert {:error, :omp_expired_token} = OmpToken.resolve(path)
    fresh = jwt(3600)
    script(path, "printf '%s' '#{fresh}'")
    assert {:ok, ^fresh} = OmpToken.resolve(path)
  end

  test "refresh window does not reuse a nearly expired token", %{path: path} do
    near = jwt(60)
    script(path, "printf '%s' '#{near}'")
    assert {:ok, ^near} = OmpToken.resolve(path)
    fresh = jwt(3600)
    script(path, "printf '%s' '#{fresh}'")
    assert {:ok, ^fresh} = OmpToken.resolve(path)
  end

  test "force refresh passes flag and discards rejected cached token even on failure", %{
    path: path
  } do
    token = jwt(3600)
    script(path, "printf '%s' '#{token}'")
    assert {:ok, ^token} = OmpToken.resolve(path)
    script(path, "test \"$3\" = --force-refresh || exit 8; exit 2")

    assert {:error, :omp_exit_nonzero} =
             Task.async(fn -> OmpToken.resolve(path, force_refresh: true) end) |> Task.await()

    script(path, "printf 'not-a-token'")
    assert {:error, :omp_invalid_token} = OmpToken.resolve(path)
  end

  test "forced refresh waits for an in-flight miss and leaves only the fresh token cached", %{
    path: path,
    dir: dir
  } do
    entered = Path.join(dir, "entered")
    release = Path.join(dir, "release")
    calls = Path.join(dir, "calls")
    assert {"", 0} = System.cmd("mkfifo", [entered, release])
    original = jwt(1800)
    fresh = jwt(3600)

    script(path, """
    if [ "${3-}" = --force-refresh ]; then
      printf 'force\\n' >> '#{calls}'
      printf '%s\\n' '#{fresh}'
    else
      printf 'normal\\n' >> '#{calls}'
      printf started > '#{entered}'
      read -r release < '#{release}'
      printf '%s\\n' '#{original}'
    fi
    """)

    notification =
      Task.async(fn ->
        # Raw I/O keeps the FIFO handshake off the shared Erlang file server,
        # which credential discovery also needs for executable stat calls.
        {:ok, fifo} = :file.open(String.to_charlist(entered), [:read, :raw, :binary])

        try do
          {:ok, message} = :file.read(fifo, 7)
          message
        after
          :file.close(fifo)
        end
      end)

    ordinary = Task.async(fn -> OmpToken.resolve(path) end)
    assert Task.await(notification, 5_000) == "started"
    caller = self()

    forced =
      Task.async(fn ->
        send(caller, :force_requested)
        OmpToken.resolve(path, force_refresh: true)
      end)

    assert_receive :force_requested

    try do
      # The first subprocess is blocked on our FIFO, not on a timing delay.
      # A forced refresh must remain pending until that fetch can publish.
      assert Task.yield(forced, 1_000) == nil
    after
      File.write!(release, "continue\n")
    end

    assert {:ok, ^original} = Task.await(ordinary, 5_000)
    assert {:ok, ^fresh} = Task.await(forced, 5_000)
    assert {:ok, ^fresh} = Task.async(fn -> OmpToken.resolve(path) end) |> Task.await()
    assert File.read!(calls) == "normal\nforce\n"
  end

  test "missing and non-executable paths produce actionable credential-free guidance", %{
    path: path
  } do
    assert {:error, :omp_not_found} = OmpToken.resolve(path)
    File.write!(path, "not executable")
    assert {:error, :omp_not_found} = OmpToken.resolve(path)
    assert OmpToken.error_message(:omp_not_found) =~ "omp_path"
    assert {:error, :omp_not_found} = OmpToken.discover("relative/omp")
  end

  test "non-zero exits discard stdout and stderr", %{path: path} do
    script(path, "printf 'private-access-token'; printf 'private-refresh-token' >&2; exit 1")
    assert {:error, :omp_exit_nonzero} = OmpToken.resolve(path)
    message = OmpToken.error_message(:omp_exit_nonzero)
    assert message =~ "`omp` and `/login kimi-code`"
    refute message =~ "private"
  end

  test "non-JWT, API keys and oversized output are refused", %{path: path} do
    for value <- ["", "sk-secret", "some diagnostic text", "a.b.c"] do
      script(path, "printf '%s' '#{value}'")
      assert {:error, :omp_invalid_token} = OmpToken.resolve(path)
    end

    script(path, "i=0; while test $i -lt 7000; do printf '0123456789'; i=$((i+1)); done")
    assert {:error, :omp_output_too_large} = OmpToken.resolve(path)
  end

  defp jwt(offset) do
    claims = Jason.encode!(%{"exp" => System.system_time(:second) + offset, "sub" => "fixture"})
    "eyJhbGciOiJIUzI1NiJ9." <> Base.url_encode64(claims, padding: false) <> ".signature"
  end

  defp script(path, body) do
    File.write!(path, "#!/bin/sh\nset -eu\n" <> body <> "\n")
    File.chmod!(path, 0o700)
  end
end
