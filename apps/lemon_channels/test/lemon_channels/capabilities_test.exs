defmodule LemonChannels.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Capabilities

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
end
