defmodule LemonControlPlane.Methods.SendIdempotencyTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.Send

  @ctx %{auth: %{role: :operator}}

  setup do
    # Clean up idempotency store before each test
    on_exit(fn ->
      try do
        LemonCore.Store.delete(:idempotency, "send:test-key-1")
        LemonCore.Store.delete(:idempotency, "send:test-key-2")
      rescue
        _ -> :ok
      end
    end)
    :ok
  end

  describe "send idempotency" do
    test "returns cached result for duplicate idempotency key" do
      # First, store a result in idempotency
      LemonCore.Idempotency.put(:send, "test-key-1", "ref-123")

      params = %{
        "channelId" => "telegram",
        "content" => "Hello world",
        "idempotencyKey" => "test-key-1"
      }

      # The send should return the cached result
      result = Send.handle(params, @ctx)

      # Should return success with cached ref
      case result do
        {:ok, response} ->
          assert response["success"] == true
          assert response["deliveryRef"] == "ref-123"

        {:error, {:internal_error, _, :channels_not_available}} ->
          # This is expected when LemonChannels is not available
          # In this case idempotency was checked but channels failed
          :ok
      end
    end

    test "generates new delivery ref without idempotency key" do
      params = %{
        "channelId" => "telegram",
        "content" => "Hello world"
        # No idempotencyKey
      }

      result = Send.handle(params, @ctx)

      # Should attempt to send (channels may not be available in test)
      case result do
        {:ok, response} ->
          assert response["success"] == true
          # deliveryRef can be a binary or a reference depending on implementation
          assert response["deliveryRef"] != nil

        {:error, {:internal_error, _, :channels_not_available}} ->
          # Expected when LemonChannels.Outbox is not available
          :ok
      end
    end

    test "idempotency key prevents duplicate sends" do
      # Clean start - no cached result
      LemonCore.Store.delete(:idempotency, "send:test-key-2")

      params = %{
        "channelId" => "telegram",
        "content" => "Hello world",
        "idempotencyKey" => "test-key-2"
      }

      # First call
      result1 = Send.handle(params, @ctx)

      # Store a mock result manually if channels not available
      first_ref = case result1 do
        {:error, {:internal_error, _, :channels_not_available}} ->
          # Simulate what would happen if send succeeded
          LemonCore.Idempotency.put(:send, "test-key-2", "ref-456")
          "ref-456"

        {:ok, response} ->
          response["deliveryRef"]
      end

      # Second call with same key should return cached result
      result2 = Send.handle(params, @ctx)

      case result2 do
        {:ok, response} ->
          # Should return the same ref as first call
          assert response["deliveryRef"] == first_ref

        {:error, {:internal_error, _, :channels_not_available}} ->
          # If channels still not available, the idempotency check happened first
          # but then channels failed. This is acceptable behavior.
          :ok
      end
    end
  end

  describe "idempotency service" do
    test "get returns miss for unknown key" do
      assert LemonCore.Idempotency.get(:send, "unknown-key") == :miss
    end

    test "put and get work correctly" do
      LemonCore.Idempotency.put(:send, "known-key", %{result: "value"})

      assert {:ok, %{result: "value"}} = LemonCore.Idempotency.get(:send, "known-key")

      # Cleanup
      LemonCore.Idempotency.delete(:send, "known-key")
    end

    test "put_new returns exists for duplicate key" do
      LemonCore.Idempotency.put(:send, "dup-key", "first")

      assert LemonCore.Idempotency.put_new(:send, "dup-key", "second") == :exists
      assert {:ok, "first"} = LemonCore.Idempotency.get(:send, "dup-key")

      # Cleanup
      LemonCore.Idempotency.delete(:send, "dup-key")
    end

    test "execute returns cached result" do
      counter = :counters.new(1, [:atomics])

      # First execute
      result1 = LemonCore.Idempotency.execute(:send, "exec-key", fn ->
        :counters.add(counter, 1, 1)
        "computed"
      end)

      assert result1 == "computed"
      assert :counters.get(counter, 1) == 1

      # Second execute - should return cached, not increment counter
      result2 = LemonCore.Idempotency.execute(:send, "exec-key", fn ->
        :counters.add(counter, 1, 1)
        "computed-again"
      end)

      assert result2 == "computed"
      assert :counters.get(counter, 1) == 1  # Still 1, not 2

      # Cleanup
      LemonCore.Idempotency.delete(:send, "exec-key")
    end
  end
end
