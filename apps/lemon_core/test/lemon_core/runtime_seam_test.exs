defmodule LemonCore.RuntimeSeamTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.RuntimeSeam

  @setting :runtime_seam_consolidation_test

  defmodule Contract do
    @callback answer(term()) :: term()
  end

  defmodule Provider do
    @behaviour Contract

    @impl true
    def answer(value), do: value
    def fail(:raise), do: raise("private exception content")
    def fail(:exit), do: exit({:timeout, "private exit content"})
    def fail(:throw), do: throw("private throw content")

    def mutation(owner) do
      send(owner, :mutation_applied)
      raise "private mutation content"
    end
  end

  defmodule OtherProvider do
    @behaviour Contract

    @impl true
    def answer(value), do: value
  end

  setup do
    original = Application.fetch_env(:lemon_core, @setting)
    Application.delete_env(:lemon_core, @setting)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:lemon_core, @setting, value)
        :error -> Application.delete_env(:lemon_core, @setting)
      end
    end)

    :ok
  end

  test "single registrations share validation and guarded replacement" do
    assert :ok = RuntimeSeam.register(@setting, Provider, Contract)
    assert Provider == RuntimeSeam.provider(@setting)

    assert {:error, {:already_configured, Provider}} =
             RuntimeSeam.configure_provider(@setting, OtherProvider, :if_unset)

    assert :ok = RuntimeSeam.configure_provider(@setting, Provider, :if_unset)

    assert {:error, :already_configured} =
             RuntimeSeam.configure_provider(@setting, nil, :if_unset)

    assert :ok = RuntimeSeam.unregister(@setting)
    assert is_nil(RuntimeSeam.provider(@setting))
  end

  test "all role validation precedes replacement and guarded merges preserve registrations" do
    roles = [first: Contract, second: Contract]
    assert :ok = RuntimeSeam.configure(@setting, [first: Provider], roles, :replace)

    assert {:error, {:invalid_implementation, :second, _}} =
             RuntimeSeam.configure(
               @setting,
               [first: OtherProvider, second: __MODULE__],
               roles,
               :merge
             )

    assert %{first: Provider} == RuntimeSeam.config(@setting, Keyword.keys(roles))

    assert {:error, {:already_configured, :first, Provider, OtherProvider}} =
             RuntimeSeam.configure(@setting, [first: OtherProvider], roles, :safe_merge)

    assert :ok = RuntimeSeam.configure(@setting, [second: OtherProvider], roles, :safe_merge)

    assert %{first: Provider, second: OtherProvider} ==
             RuntimeSeam.config(@setting, Keyword.keys(roles))

    assert :ok = RuntimeSeam.configure(@setting, [first: nil], roles, :merge)
    assert %{second: OtherProvider} == RuntimeSeam.config(@setting, Keyword.keys(roles))
  end

  test "dispatch preserves values and distinguishes absent and missing callbacks" do
    assert {:ok, :value} = RuntimeSeam.invoke(Provider, :answer, [{:ok, :value}], [])
    assert :absent = RuntimeSeam.invoke(nil, :answer, [], unavailable: :absent, missing: :missing)

    assert :missing =
             RuntimeSeam.invoke(Provider, :missing, [], unavailable: :absent, missing: :missing)
  end

  test "all callback failure classes use policy values without leaking callback data" do
    log =
      capture_log(fn ->
        for kind <- [:raise, :exit, :throw] do
          assert {:error, :outcome_unknown} =
                   RuntimeSeam.invoke(Provider, :fail, [kind],
                     unavailable: {:error, :outcome_unknown},
                     log: "RuntimeSeam"
                   )
        end
      end)

    assert log =~ "failure_class=exception"
    assert log =~ "failure_class=timeout"
    assert log =~ "failure_class=throw"
    refute log =~ "private"
  end

  test "a reached mutation failure is never replayed" do
    assert {:error, :outcome_unknown} =
             RuntimeSeam.invoke(Provider, :mutation, [self()],
               unavailable: {:error, :unavailable},
               exception: {:error, :outcome_unknown}
             )

    assert_received :mutation_applied
    refute_received :mutation_applied
  end
end
