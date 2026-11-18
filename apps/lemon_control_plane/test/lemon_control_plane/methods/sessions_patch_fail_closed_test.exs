defmodule LemonControlPlane.Methods.SessionsPatchFailClosedTest do
  # Swaps the default Store's backend, so it cannot run beside other tests.
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.SessionsPatch
  alias LemonCore.{PolicyStore, Store}
  alias LemonCore.Store.EtsBackend

  # Fails reads of the session policy table, or reports a landed write as an
  # unknown outcome, inside the real Store process.
  defmodule FaultBackend do
    @behaviour LemonCore.Store.Backend

    def set(fault) do
      :persistent_term.erase({__MODULE__, :writes})
      :persistent_term.put({__MODULE__, :fault}, fault)
    end

    def clear, do: :persistent_term.erase({__MODULE__, :fault})
    defp fault, do: :persistent_term.get({__MODULE__, :fault}, nil)

    defdelegate init(opts), to: EtsBackend
    # `:landed_unknown` commits the write and then reports an unknown outcome,
    # the way a Store write timeout does.
    def put(state, :session_policies, key, value) do
      case fault() do
        :landed_unknown ->
          :persistent_term.put({__MODULE__, :writes}, writes() + 1)
          {:ok, _state} = EtsBackend.put(state, :session_policies, key, value)
          {:error, :outcome_unknown}

        _ ->
          EtsBackend.put(state, :session_policies, key, value)
      end
    end

    def put(state, table, key, value), do: EtsBackend.put(state, table, key, value)

    def writes, do: :persistent_term.get({__MODULE__, :writes}, 0)
    defdelegate put_new(state, table, key, value), to: EtsBackend
    defdelegate delete(state, table, key), to: EtsBackend
    defdelegate list(state, table), to: EtsBackend
    defdelegate sync(state), to: EtsBackend

    def get(state, :session_policies, key) do
      if fault() == :error,
        do: {:error, :boom},
        else: EtsBackend.get(state, :session_policies, key)
    end

    def get(state, table, key), do: EtsBackend.get(state, table, key)
  end

  setup do
    %{backend: EtsBackend} = :sys.get_state(Store)
    :sys.replace_state(Store, &%{&1 | backend: FaultBackend})

    on_exit(fn ->
      FaultBackend.clear()
      :sys.replace_state(Store, &%{&1 | backend: EtsBackend})
    end)

    session_key = "agent:test:main:patch-#{System.unique_integer([:positive])}"
    :ok = PolicyStore.put_session(session_key, %{tool_policy: %{deny: ["bash"]}, model: "m1"})
    on_exit(fn -> Store.delete(:session_policies, session_key) end)
    %{session_key: session_key}
  end

  test "an unreadable session policy rejects the patch instead of erasing its tool policy",
       ctx do
    FaultBackend.set(:error)

    assert {:error, _reason} =
             SessionsPatch.handle(%{"sessionKey" => ctx.session_key, "model" => "m2"}, %{
               auth: %{role: :operator}
             })

    FaultBackend.clear()

    assert {:ok, %{tool_policy: %{deny: ["bash"]}, model: "m1"}} =
             Store.fetch(:session_policies, ctx.session_key)
  end

  test "a policy write with an unknown outcome is reported as unknown, never success", ctx do
    FaultBackend.set(:landed_unknown)

    result =
      SessionsPatch.handle(
        %{"sessionKey" => ctx.session_key, "model" => "restricted-model"},
        %{auth: %{role: :operator}}
      )

    FaultBackend.clear()

    assert {:error,
            {:unavailable, _message,
             %{"code" => "SESSION_PATCH_OUTCOME_UNKNOWN", "retrySafe" => false}}} = result

    # Never retried automatically: exactly one write was attempted.
    assert FaultBackend.writes() == 1
  end
end
