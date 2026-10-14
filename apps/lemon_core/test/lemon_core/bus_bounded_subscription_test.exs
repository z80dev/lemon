defmodule LemonCore.BusBoundedSubscriptionTest do
  use ExUnit.Case, async: false

  alias LemonCore.Bus
  alias LemonCore.Bus.Delivery

  setup do
    original = Application.get_env(:lemon_core, :bus_backend)

    unless Process.whereis(LemonCore.Bus.Registry) do
      start_supervised!({Registry, keys: :duplicate, name: LemonCore.Bus.Registry})
    end

    unless Process.whereis(LemonCore.PubSub) do
      start_supervised!({Phoenix.PubSub, name: LemonCore.PubSub})
    end

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_core, :bus_backend)
      else
        Application.put_env(:lemon_core, :bus_backend, original)
      end
    end)

    :ok
  end

  for backend <- [:registry, :pubsub], tagged <- [false, true] do
    test "#{backend} bounds shared multi-topic ingress before the mailbox (tagged=#{tagged})" do
      Application.put_env(:lemon_core, :bus_backend, unquote(backend))
      parent = self()
      suffix = System.unique_integer([:positive])
      topics = ["bounded:a:#{suffix}", "bounded:b:#{suffix}"]

      pid =
        spawn(fn ->
          delivery = Delivery.new(self(), max_queue: 4, max_bytes: 256, tagged: unquote(tagged))
          for topic <- topics, do: Bus.subscribe(topic, delivery: delivery)
          send(parent, {:subscribed, self()})

          receive do
            :drain -> send(parent, {:drained, self(), collect([])})
          end
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      assert_receive {:subscribed, ^pid}

      for n <- 1..500 do
        assert :ok = Bus.broadcast(Enum.at(topics, rem(n, 2)), {:progress, n})
      end

      # PubSub's local dispatch is synchronous; no sleeps or eventual mailbox
      # sampling is needed to establish the producer-side admission threshold.
      assert {:message_queue_len, 5} = Process.info(pid, :message_queue_len)
      send(pid, :drain)
      assert_receive {:drained, ^pid, messages}

      assert Enum.reduce(messages, 0, fn message, bytes ->
               bytes + :erlang.external_size(message)
             end) <= 4 * 256 + 1024

      messages =
        Enum.map(messages, fn
          {:lemon_bus_delivery, _gate, event} -> event
          event -> event
        end)

      assert Enum.count(messages, &match?({:progress, _}, &1)) == 4
      assert Enum.count(messages, &(&1 == {:stream_resync, :overflow})) == 1
    end
  end

  defp collect(acc) do
    receive do
      message -> collect([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
