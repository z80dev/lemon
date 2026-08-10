defmodule XApi.ChannelAdapterTest do
  @moduledoc """
  The satellite describes its own capabilities.

  These assertions previously lived in `lemon_channels` as a hard-coded
  `Capabilities.Registry.lookup("x_api")` clause — the platform asserting facts
  about a satellite it is not supposed to know exists (D7). That table has been
  deleted; the adapter's own `meta/0` is the single source of truth, and the
  280-character limit is asserted here, next to the code that would change it.
  """
  use ExUnit.Case, async: true

  alias XApi.ChannelAdapter

  describe "meta/0" do
    test "declares the 280-character post limit" do
      assert ChannelAdapter.meta().capabilities.chunk_limit == 280
    end

    test "declares edit and delete support but not voice" do
      caps = ChannelAdapter.meta().capabilities

      assert caps.edit_support == true
      assert caps.delete_support == true
      assert caps.voice_support == false
      assert caps.image_support == true
    end

    test "declares a rate limit" do
      assert ChannelAdapter.meta().capabilities.rate_limit == 2400
    end

    test "carries a human-readable label" do
      assert is_binary(ChannelAdapter.meta().label)
    end
  end

  describe "id/0" do
    test "matches the id the platform registers the adapter under" do
      assert ChannelAdapter.id() == "x_api"
    end
  end
end
