defmodule LemonCore.StoreSecretRedactionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias LemonCore.Store

  defmodule RefusingBackend do
    @behaviour LemonCore.Store.Backend
    def init(_), do: {:ok, %{}}
    def put(_, _, _, _), do: {:error, %{name: "private-secret-name", fingerprint: "private-intent-fingerprint"}}
    def put_new(_, _, _, _), do: {:error, %{name: "private-secret-name", fingerprint: "private-intent-fingerprint"}}
    def get(state, _, _), do: {:ok, nil, state}
    def delete(state, _, _), do: {:ok, state}
    def list(state, _), do: {:ok, [], state}
  end

  test "vault, key-lock and native process receipt diagnostics never expose private inputs or fingerprints" do
    server = start_supervised!({Store, name: __MODULE__.Store, backend: RefusingBackend})
    for table <- [:secrets_v1, :secrets_lock, :node_process_receipts] do
      logs = capture_log(fn ->
        assert {:error, _} = Store.put(server, table, {"private-owner", "private-secret-name"}, %{"private" => "private-value"})
        assert {:error, _} = Store.put_new(server, table, {"private-owner", "private-secret-name"}, %{"private" => "private-value"})
      end)
      refute logs =~ "private-secret-name"
      refute logs =~ "private-intent-fingerprint"
      refute logs =~ "private-owner"
      refute logs =~ "private-value"
    end
  end
end
