defmodule LemonCore.CodeReloadTest do
  use ExUnit.Case, async: false

  alias LemonCore.CodeReload

  setup do
    module = :lemon_code_reload_test_fixture
    dir = Path.join(System.tmp_dir!(), "lemon-reload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    :code.add_patha(String.to_charlist(dir))

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
      :code.del_path(String.to_charlist(dir))
      File.rm_rf!(dir)
    end)

    %{module: module, dir: dir}
  end

  test "loads changed on-disk code and respects directory boundaries", %{module: module, dir: dir} do
    write_beam(module, dir, 1)
    assert {:module, ^module} = :code.load_file(module)
    assert apply(module, :value, []) == 1
    write_beam(module, dir, 2)

    assert CodeReload.reload_modified(only_under: [dir <> "-other"]).reloaded == []
    assert %{reloaded: [^module], in_use: [], failed: []} =
             CodeReload.reload_modified(only_under: [dir])

    assert apply(module, :value, []) == 2
  end

  test "does not kill processes executing the previous old version", %{module: module, dir: dir} do
    write_beam(module, dir, 1)
    assert {:module, ^module} = :code.load_file(module)
    pid = spawn(module, :wait, [self()])
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {:ready, ^pid}

    write_beam(module, dir, 2)
    assert {:module, ^module} = :code.load_file(module)
    write_beam(module, dir, 3)

    assert %{reloaded: [], in_use: [^module], failed: []} =
             CodeReload.reload_modified(only_under: [dir])

    assert Process.alive?(pid)
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert %{reloaded: [^module], in_use: [], failed: []} = CodeReload.retry_in_use([module])
    assert apply(module, :value, []) == 3
  end

  test "reports load errors without raising", %{module: module} do
    assert %{reloaded: [], in_use: [], failed: [{^module, :nofile}]} =
             CodeReload.retry_in_use([module])
  end

  defp write_beam(module, dir, version) do
    source = """
    -module(#{module}).
    -export([value/0, wait/1]).
    value() -> #{version}.
    wait(Parent) -> Parent ! {ready, self()}, receive stop -> ok end.
    """

    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))

    {forms, []} =
      Enum.reduce(tokens, {[], []}, fn token, {forms, current} ->
        case token do
          {:dot, _} ->
            {:ok, form} = :erl_parse.parse_form(Enum.reverse([token | current]))
            {[form | forms], []}

          _ ->
            {forms, [token | current]}
        end
      end)

    {:ok, ^module, beam} = :compile.forms(Enum.reverse(forms), [:binary])
    File.write!(Path.join(dir, "#{module}.beam"), beam)
  end
end
