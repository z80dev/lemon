defmodule LemonChannels.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Capabilities
  alias LemonChannels.Capabilities.Capability

  test "supports?/2 honours presence and the enabled flag" do
    caps = Capabilities.new([:threads, {:attachments, enabled: false}])

    assert Capabilities.supports?(caps, :threads)
    refute Capabilities.supports?(caps, :streaming)
    refute Capabilities.supports?(caps, :attachments)
  end

  test "supports_feature?/3 requires both the capability and the feature" do
    caps = Capabilities.new([{:rich_blocks, [:markdown, :buttons]}])

    assert Capabilities.supports_feature?(caps, :rich_blocks, :buttons)
    refute Capabilities.supports_feature?(caps, :rich_blocks, :tables)
    refute Capabilities.supports_feature?(Capabilities.new([:threads]), :rich_blocks, :markdown)
  end

  describe "validate/3" do
    test "enforces attachment size and wildcard mime allowlists" do
      caps = Capabilities.new([{:attachments, max_size: 10_000_000, allowed_mimes: ["image/*"]}])

      assert :ok =
               Capabilities.validate(caps, :attachments, %{size: 1000, mime_type: "image/jpeg"})

      assert {:error, :file_too_large} =
               Capabilities.validate(caps, :attachments, %{
                 size: 15_000_000,
                 mime_type: "image/png"
               })

      assert {:error, :mime_type_not_allowed} =
               Capabilities.validate(caps, :attachments, %{
                 size: 1000,
                 mime_type: "application/exe"
               })
    end

    test "rejects missing and disabled capabilities" do
      assert {:error, :capability_not_supported} =
               Capabilities.validate(Capabilities.new([:threads]), :attachments, %{size: 1000})

      assert {:error, :capability_disabled} =
               Capabilities.validate(
                 Capabilities.new([{:attachments, enabled: false}]),
                 :attachments,
                 %{size: 1000}
               )
    end

    test "validates rich block types" do
      caps = Capabilities.new([{:rich_blocks, [:markdown, :buttons]}])

      assert :ok = Capabilities.validate(caps, :rich_blocks, %{type: :markdown})

      assert {:error, {:block_type_not_supported, :tables}} =
               Capabilities.validate(caps, :rich_blocks, %{type: :tables})
    end
  end

  describe "list/1" do
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

  test "to_legacy/1 converts new format to legacy" do
    caps =
      Capabilities.new([
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

  test "from_legacy/1 maps plugin metadata flags onto capabilities" do
    caps =
      Capabilities.from_legacy(%{
        edit_support: true,
        delete_support: true,
        thread_support: true,
        reaction_support: true,
        voice_support: false,
        image_support: true,
        file_support: true,
        chunk_limit: 2000,
        rate_limit: 30
      })

    for capability <- [:edit, :delete, :threads, :reactions, :attachments] do
      assert Capabilities.supports?(caps, capability)
    end

    assert Capabilities.get(caps, :chunk_limit).config.value == 2000
  end

  describe "Capability module" do
    test "from_spec/1 returns nil for invalid input" do
      assert Capability.from_spec("invalid") == nil
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

    test "register_set/1 stores custom set" do
      custom_caps = [Capability.new(:custom, enabled: true)]
      :ok = Registry.register_set(:custom, custom_caps)

      assert Capabilities.set(:custom) == custom_caps
    end
  end
end
