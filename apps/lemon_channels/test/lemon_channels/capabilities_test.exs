defmodule LemonChannels.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Capabilities
  alias LemonChannels.Capabilities.Capability

  describe "new/1" do
    test "creates capabilities from simple atom list" do
      caps = Capabilities.new([:threads, :reactions, :streaming])

      assert Capabilities.supports?(caps, :threads)
      assert Capabilities.supports?(caps, :reactions)
      assert Capabilities.supports?(caps, :streaming)
      refute Capabilities.supports?(caps, :attachments)
    end

    test "creates capabilities with configuration" do
      caps = Capabilities.new([
        {:attachments, max_size: 10_000_000},
        {:rich_blocks, [:markdown, :buttons]}
      ])

      assert Capabilities.supports?(caps, :attachments)
      assert Capabilities.supports?(caps, :rich_blocks)

      attachment_cap = Capabilities.get(caps, :attachments)
      assert attachment_cap.config.max_size == 10_000_000
    end

    test "includes default capabilities" do
      caps = Capabilities.new([])

      # Default edit/delete are false
      refute Capabilities.supports?(caps, :edit)
      refute Capabilities.supports?(caps, :delete)

      # But chunk_limit is always present
      assert Capabilities.get(caps, :chunk_limit) != nil
    end
  end

  describe "supports?/2" do
    test "returns true for supported capabilities" do
      caps = Capabilities.new([:threads, :reactions])

      assert Capabilities.supports?(caps, :threads)
      assert Capabilities.supports?(caps, :reactions)
    end

    test "returns false for unsupported capabilities" do
      caps = Capabilities.new([:threads])

      refute Capabilities.supports?(caps, :streaming)
      refute Capabilities.supports?(caps, :unknown_capability)
    end

    test "returns false for disabled capabilities" do
      caps = Capabilities.new([{:attachments, enabled: false}])

      refute Capabilities.supports?(caps, :attachments)
    end
  end

  describe "supports_feature?/3" do
    test "returns true for supported features" do
      caps = Capabilities.new([{:rich_blocks, [:markdown, :buttons]}])

      assert Capabilities.supports_feature?(caps, :rich_blocks, :markdown)
      assert Capabilities.supports_feature?(caps, :rich_blocks, :buttons)
    end

    test "returns false for unsupported features" do
      caps = Capabilities.new([{:rich_blocks, [:markdown]}])

      refute Capabilities.supports_feature?(caps, :rich_blocks, :tables)
    end

    test "returns false for unsupported capability" do
      caps = Capabilities.new([:threads])

      refute Capabilities.supports_feature?(caps, :rich_blocks, :markdown)
    end
  end

  describe "get/2" do
    test "returns capability struct when present" do
      caps = Capabilities.new([{:attachments, max_size: 5_000_000}])

      cap = Capabilities.get(caps, :attachments)
      assert %Capability{} = cap
      assert cap.type == :attachments
      assert cap.config.max_size == 5_000_000
    end

    test "returns nil for missing capability" do
      caps = Capabilities.new([:threads])

      assert Capabilities.get(caps, :attachments) == nil
    end
  end

  describe "validate/3" do
    test "returns ok for valid attachment" do
      caps = Capabilities.new([{:attachments, max_size: 10_000_000}])

      assert :ok = Capabilities.validate(caps, :attachments, %{size: 5_000_000, mime_type: "image/png"})
    end

    test "returns error for oversized attachment" do
      caps = Capabilities.new([{:attachments, max_size: 10_000_000}])

      assert {:error, :file_too_large} =
               Capabilities.validate(caps, :attachments, %{size: 15_000_000, mime_type: "image/png"})
    end

    test "returns error for unsupported mime type" do
      caps = Capabilities.new([{:attachments, max_size: 10_000_000, allowed_mimes: ["image/*"]}])

      assert {:error, :mime_type_not_allowed} =
               Capabilities.validate(caps, :attachments, %{size: 5_000_000, mime_type: "application/exe"})
    end

    test "allows wildcard mime patterns" do
      caps = Capabilities.new([{:attachments, allowed_mimes: ["image/*"]}])

      assert :ok = Capabilities.validate(caps, :attachments, %{size: 1000, mime_type: "image/png"})
      assert :ok = Capabilities.validate(caps, :attachments, %{size: 1000, mime_type: "image/jpeg"})
    end

    test "returns error for unsupported capability" do
      caps = Capabilities.new([:threads])

      assert {:error, :capability_not_supported} =
               Capabilities.validate(caps, :attachments, %{size: 1000})
    end

    test "returns error for disabled capability" do
      caps = Capabilities.new([{:attachments, enabled: false}])

      assert {:error, :capability_disabled} =
               Capabilities.validate(caps, :attachments, %{size: 1000})
    end

    test "validates rich block types" do
      caps = Capabilities.new([{:rich_blocks, [:markdown, :buttons]}])

      assert :ok = Capabilities.validate(caps, :rich_blocks, %{type: :markdown})
      assert {:error, {:block_type_not_supported, :tables}} =
               Capabilities.validate(caps, :rich_blocks, %{type: :tables})
    end
  end

  describe "list/1" do
    test "returns list of supported capability types" do
      caps = Capabilities.new([:threads, :reactions])

      types = Capabilities.list(caps)
      assert :threads in types
      assert :reactions in types
    end

    test "does not include disabled capabilities" do
      caps = Capabilities.new([:threads, {:attachments, enabled: false}])

      types = Capabilities.list(caps)
      assert :threads in types
      refute :attachments in types
    end
  end

  describe "merge/2" do
    test "merges two capability maps" do
      base = Capabilities.new([:threads, {:attachments, max_size: 5_000_000}])
      override = Capabilities.new([{:attachments, max_size: 10_000_000}, :streaming])

      merged = Capabilities.merge(base, override)

      assert Capabilities.supports?(merged, :threads)
      assert Capabilities.supports?(merged, :streaming)

      # Override value takes precedence
      attachment = Capabilities.get(merged, :attachments)
      assert attachment.config.max_size == 10_000_000
    end
  end

  describe "fallback_for/2" do
    test "returns text fallback for rich_blocks" do
      caps = Capabilities.new([:threads])

      assert {:ok, {:text, _}} = Capabilities.fallback_for(caps, :rich_blocks)
    end

    test "returns link fallback for attachments" do
      caps = Capabilities.new([:threads])

      assert {:ok, {:link, _}} = Capabilities.fallback_for(caps, :attachments)
    end

    test "returns buffer fallback for streaming" do
      caps = Capabilities.new([:threads])

      assert {:ok, {:buffer, _}} = Capabilities.fallback_for(caps, :streaming)
    end

    test "returns text_reply fallback for reactions" do
      caps = Capabilities.new([:threads])

      assert {:ok, {:text_reply, _}} = Capabilities.fallback_for(caps, :reactions)
    end

    test "returns error for unknown capability" do
      caps = Capabilities.new([:threads])

      assert {:error, :no_fallback} = Capabilities.fallback_for(caps, :unknown)
    end
  end

  describe "set/1" do
    test "returns messaging set" do
      caps = Capabilities.set(:messaging)

      assert length(caps) > 0
      assert Enum.any?(caps, &(&1.type == :threads))
      assert Enum.any?(caps, &(&1.type == :reactions))
    end

    test "returns rich_content set" do
      caps = Capabilities.set(:rich_content)

      assert Enum.any?(caps, &(&1.type == :attachments))
      assert Enum.any?(caps, &(&1.type == :rich_blocks))
    end

    test "returns realtime set" do
      caps = Capabilities.set(:realtime)

      assert Enum.any?(caps, &(&1.type == :streaming))
    end

    test "returns full set" do
      caps = Capabilities.set(:full)

      assert length(caps) >= 6
    end

    test "returns empty list for unknown set" do
      assert Capabilities.set(:unknown) == []
    end
  end

  describe "legacy compatibility" do
    test "defaults/0 returns legacy format" do
      defaults = Capabilities.defaults()

      assert defaults.edit_support == false
      assert defaults.chunk_limit == 4096
      assert defaults.thread_support == false
    end

    test "with_defaults/1 merges with defaults" do
      caps = Capabilities.with_defaults(%{thread_support: true, chunk_limit: 2000})

      assert caps.thread_support == true
      assert caps.chunk_limit == 2000
      assert caps.edit_support == false  # from defaults
    end

    test "to_legacy/1 converts new format to legacy" do
      caps = Capabilities.new([
        :threads,
        :reactions,
        :edit,
        :delete,
        {:attachments, features: [:images]}
      ])

      legacy = Capabilities.to_legacy(caps)

      assert legacy.thread_support == true
      assert legacy.reaction_support == true
      assert legacy.edit_support == true
      assert legacy.delete_support == true
      assert legacy.image_support == true
      assert legacy.file_support == true
    end

    test "from_legacy/1 converts legacy format to new" do
      legacy = %{
        edit_support: true,
        delete_support: true,
        thread_support: true,
        reaction_support: true,
        voice_support: false,
        image_support: true,
        file_support: true,
        chunk_limit: 2000,
        rate_limit: 30
      }

      caps = Capabilities.from_legacy(legacy)

      assert Capabilities.supports?(caps, :edit)
      assert Capabilities.supports?(caps, :delete)
      assert Capabilities.supports?(caps, :threads)
      assert Capabilities.supports?(caps, :reactions)
      assert Capabilities.supports?(caps, :attachments)

      chunk_cap = Capabilities.get(caps, :chunk_limit)
      assert chunk_cap.config.value == 2000
    end
  end

  describe "Capability module" do
    test "new/2 creates capability" do
      cap = Capability.new(:threads, enabled: true)

      assert cap.type == :threads
      assert cap.enabled == true
    end

    test "from_spec/1 handles simple atoms" do
      cap = Capability.from_spec(:threads)

      assert cap.type == :threads
      assert cap.enabled == true
    end

    test "from_spec/1 handles tuples with options" do
      cap = Capability.from_spec({:attachments, max_size: 5_000_000})

      assert cap.type == :attachments
      assert cap.config.max_size == 5_000_000
    end

    test "from_spec/1 handles tuples with feature lists" do
      cap = Capability.from_spec({:rich_blocks, [:markdown, :buttons]})

      assert cap.type == :rich_blocks
      assert :markdown in cap.config.features
    end

    test "from_spec/1 returns nil for invalid input" do
      assert Capability.from_spec("invalid") == nil
    end

    test "validate/2 validates attachments" do
      cap = Capability.new(:attachments, max_size: 1000)

      assert :ok = Capability.validate(cap, %{size: 500})
      assert {:error, :file_too_large} = Capability.validate(cap, %{size: 2000})
    end

    test "merge/2 combines capabilities" do
      base = Capability.new(:attachments, max_size: 5_000_000)
      override = Capability.new(:attachments, max_size: 10_000_000, enabled: false)

      merged = Capability.merge(base, override)

      assert merged.enabled == false
      assert merged.config.max_size == 10_000_000
    end
  end

  describe "Registry module" do
    alias Capabilities.Registry

    test "lookup/1 returns telegram capabilities" do
      caps = Registry.lookup("telegram")

      assert Capabilities.supports?(caps, :threads)
      assert Capabilities.supports?(caps, :reactions)
      assert Capabilities.supports?(caps, :edit)
      assert Capabilities.supports?(caps, :voice)
      assert Capabilities.supports?(caps, :attachments)
    end

    test "lookup/1 returns discord capabilities" do
      caps = Registry.lookup("discord")

      assert Capabilities.supports?(caps, :threads)
      refute Capabilities.supports?(caps, :reactions)
      assert Capabilities.supports?(caps, :attachments)
    end

    test "lookup/1 returns x_api capabilities" do
      caps = Registry.lookup("x_api")

      assert Capabilities.supports?(caps, :threads)
      refute Capabilities.supports?(caps, :reactions)
      assert Capabilities.supports?(caps, :attachments)

      chunk_cap = Capabilities.get(caps, :chunk_limit)
      assert chunk_cap.config.value == 280
    end

    test "lookup/1 returns xmtp capabilities" do
      caps = Registry.lookup("xmtp")

      assert Capabilities.supports?(caps, :threads)
      refute Capabilities.supports?(caps, :attachments)
      refute Capabilities.supports?(caps, :rich_blocks)
    end

    test "lookup/1 handles atom input" do
      caps = Registry.lookup(:telegram)

      assert Capabilities.supports?(caps, :threads)
    end

    test "lookup/1 returns empty for unknown adapter" do
      caps = Registry.lookup(:unknown)

      assert caps == Capabilities.empty()
    end

    test "register_set/1 stores custom set" do
      custom_caps = [Capability.new(:custom, enabled: true)]
      :ok = Registry.register_set(:custom, custom_caps)

      assert Capabilities.set(:custom) == custom_caps
    end
  end

  describe "empty/0" do
    test "returns empty capabilities map" do
      assert Capabilities.empty() == %{}
    end
  end
end
