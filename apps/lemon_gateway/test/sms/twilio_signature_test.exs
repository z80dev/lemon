defmodule LemonGateway.Sms.TwilioSignatureTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Sms.TwilioSignature

  @token "test_auth_token_abc123"
  @url "https://example.com/webhooks/twilio/sms"

  # ---------------------------------------------------------------------------
  # Helper: compute the expected signature the same way Twilio documents it,
  # using :crypto.mac directly so we aren't just re-calling the module under
  # test.
  # ---------------------------------------------------------------------------
  defp compute_expected(auth_token, url, sorted_param_string) do
    data = url <> sorted_param_string
    mac = :crypto.mac(:hmac, :sha, auth_token, data)
    Base.encode64(mac)
  end

  # ---------------------------------------------------------------------------
  # signature/3 tests
  # ---------------------------------------------------------------------------
  describe "signature/3" do
    test "with empty params produces HMAC-SHA1 of URL alone" do
      expected = compute_expected(@token, @url, "")
      assert TwilioSignature.signature(@token, @url, %{}) == expected
    end

    test "with a single param" do
      params = %{"Body" => "hello"}
      expected = compute_expected(@token, @url, "Bodyhello")
      assert TwilioSignature.signature(@token, @url, params) == expected
    end

    test "with multiple params sorted alphabetically by key" do
      params = %{"To" => "+15551239999", "From" => "+15551230000", "Body" => "hi"}
      # Sorted key order: Body, From, To
      param_str = "Bodyhi" <> "From+15551230000" <> "To+15551239999"
      expected = compute_expected(@token, @url, param_str)
      assert TwilioSignature.signature(@token, @url, params) == expected
    end

    test "with atom keys converts them to strings for sorting" do
      params = %{Body: "test", From: "+1555"}
      # Atom.to_string(:Body) == "Body", Atom.to_string(:From) == "From"
      param_str = "Bodytest" <> "From+1555"
      expected = compute_expected(@token, @url, param_str)
      assert TwilioSignature.signature(@token, @url, params) == expected
    end

    test "with mixed atom and string keys" do
      params = %{"Zebra" => "z", alpha: "a"}
      # "alpha" < "Zebra" in Elixir default term ordering? No -- uppercase letters
      # have lower codepoints than lowercase, so "Zebra" < "alpha".
      param_str = "Zebraz" <> "alphaa"
      expected = compute_expected(@token, @url, param_str)
      assert TwilioSignature.signature(@token, @url, params) == expected
    end

    test "with integer value" do
      params = %{"Count" => 42}
      param_str = "Count42"
      expected = compute_expected(@token, @url, param_str)
      assert TwilioSignature.signature(@token, @url, params) == expected
    end

    test "with float value" do
      params = %{"Price" => 9.99}
      float_str = :erlang.float_to_binary(9.99, [:compact])
      param_str = "Price" <> float_str
      expected = compute_expected(@token, @url, param_str)
      assert TwilioSignature.signature(@token, @url, params) == expected
    end

    test "with nil value treated as empty string" do
      params = %{"Empty" => nil}
      param_str = "Empty"
      expected = compute_expected(@token, @url, param_str)
      assert TwilioSignature.signature(@token, @url, params) == expected
    end

    test "with list value joins elements" do
      params = %{"Items" => ["a", "b", "c"]}
      param_str = "Itemsabc"
      expected = compute_expected(@token, @url, param_str)
      assert TwilioSignature.signature(@token, @url, params) == expected
    end

    test "with list containing mixed types" do
      params = %{"Mixed" => ["hello", 42, nil]}
      param_str = "Mixedhello42"
      expected = compute_expected(@token, @url, param_str)
      assert TwilioSignature.signature(@token, @url, params) == expected
    end

    test "different tokens produce different signatures" do
      params = %{"Body" => "same"}
      sig_a = TwilioSignature.signature("token_a", @url, params)
      sig_b = TwilioSignature.signature("token_b", @url, params)
      assert sig_a != sig_b
    end

    test "different URLs produce different signatures" do
      params = %{"Body" => "same"}
      sig_a = TwilioSignature.signature(@token, "https://a.example.com/hook", params)
      sig_b = TwilioSignature.signature(@token, "https://b.example.com/hook", params)
      assert sig_a != sig_b
    end

    test "result is a valid Base64-encoded string" do
      sig = TwilioSignature.signature(@token, @url, %{"X" => "1"})
      assert {:ok, _} = Base.decode64(sig)
    end

    test "result is deterministic across calls" do
      params = %{"A" => "1", "B" => "2"}
      sig1 = TwilioSignature.signature(@token, @url, params)
      sig2 = TwilioSignature.signature(@token, @url, params)
      assert sig1 == sig2
    end
  end

  # ---------------------------------------------------------------------------
  # valid?/4 tests -- happy path
  # ---------------------------------------------------------------------------
  describe "valid?/4 with correct inputs" do
    test "returns true when signature matches" do
      params = %{"From" => "+15551230000", "Body" => "hello"}
      sig = TwilioSignature.signature(@token, @url, params)
      assert TwilioSignature.valid?(@token, @url, params, sig) == true
    end

    test "returns true with empty params" do
      sig = TwilioSignature.signature(@token, @url, %{})
      assert TwilioSignature.valid?(@token, @url, %{}, sig) == true
    end

    test "returns true with atom key params" do
      params = %{Body: "test", From: "+1555"}
      sig = TwilioSignature.signature(@token, @url, params)
      assert TwilioSignature.valid?(@token, @url, params, sig) == true
    end
  end

  # ---------------------------------------------------------------------------
  # valid?/4 tests -- wrong credentials / mismatches
  # ---------------------------------------------------------------------------
  describe "valid?/4 with mismatched inputs" do
    test "returns false when token is wrong" do
      params = %{"Body" => "hello"}
      sig = TwilioSignature.signature(@token, @url, params)
      assert TwilioSignature.valid?("wrong_token", @url, params, sig) == false
    end

    test "returns false when URL is wrong" do
      params = %{"Body" => "hello"}
      sig = TwilioSignature.signature(@token, @url, params)
      assert TwilioSignature.valid?(@token, "https://wrong.example.com/hook", params, sig) == false
    end

    test "returns false when provided signature is wrong" do
      params = %{"Body" => "hello"}
      assert TwilioSignature.valid?(@token, @url, params, "dGhpcyBpcyB3cm9uZw==") == false
    end

    test "returns false when params differ" do
      params = %{"Body" => "hello"}
      sig = TwilioSignature.signature(@token, @url, params)
      assert TwilioSignature.valid?(@token, @url, %{"Body" => "goodbye"}, sig) == false
    end

    test "returns false when params have extra keys" do
      params = %{"Body" => "hello"}
      sig = TwilioSignature.signature(@token, @url, params)
      extra_params = Map.put(params, "Extra", "data")
      assert TwilioSignature.valid?(@token, @url, extra_params, sig) == false
    end
  end

  # ---------------------------------------------------------------------------
  # valid?/4 edge cases -- nil / empty / whitespace inputs
  # ---------------------------------------------------------------------------
  describe "valid?/4 edge cases" do
    test "returns false when auth_token is nil" do
      sig = TwilioSignature.signature(@token, @url, %{})
      assert TwilioSignature.valid?(nil, @url, %{}, sig) == false
    end

    test "returns false when auth_token is empty string" do
      sig = TwilioSignature.signature(@token, @url, %{})
      assert TwilioSignature.valid?("", @url, %{}, sig) == false
    end

    test "returns false when auth_token is whitespace-only" do
      sig = TwilioSignature.signature(@token, @url, %{})
      assert TwilioSignature.valid?("   ", @url, %{}, sig) == false
    end

    test "returns false when auth_token is a non-string type" do
      sig = TwilioSignature.signature(@token, @url, %{})
      assert TwilioSignature.valid?(12345, @url, %{}, sig) == false
    end

    test "returns false when url is nil" do
      sig = TwilioSignature.signature(@token, @url, %{})
      assert TwilioSignature.valid?(@token, nil, %{}, sig) == false
    end

    test "returns false when url is empty string" do
      sig = TwilioSignature.signature(@token, @url, %{})
      assert TwilioSignature.valid?(@token, "", %{}, sig) == false
    end

    test "returns false when url is whitespace-only" do
      sig = TwilioSignature.signature(@token, @url, %{})
      assert TwilioSignature.valid?(@token, "   ", %{}, sig) == false
    end

    test "returns false when url is a non-string type" do
      sig = TwilioSignature.signature(@token, @url, %{})
      assert TwilioSignature.valid?(@token, 12345, %{}, sig) == false
    end

    test "returns false when provided signature is nil" do
      assert TwilioSignature.valid?(@token, @url, %{}, nil) == false
    end

    test "returns false when provided signature is empty string" do
      assert TwilioSignature.valid?(@token, @url, %{}, "") == false
    end

    test "returns false when provided signature is whitespace-only" do
      assert TwilioSignature.valid?(@token, @url, %{}, "   ") == false
    end

    test "returns false when provided signature is a non-string type" do
      assert TwilioSignature.valid?(@token, @url, %{}, 12345) == false
    end

    test "nil params treated as empty map" do
      sig = TwilioSignature.signature(@token, @url, %{})
      assert TwilioSignature.valid?(@token, @url, nil, sig) == true
    end

    test "trims whitespace from auth_token before validating" do
      params = %{"Body" => "test"}
      sig = TwilioSignature.signature(@token, @url, params)
      assert TwilioSignature.valid?("  #{@token}  ", @url, params, sig) == true
    end

    test "trims whitespace from url before validating" do
      params = %{"Body" => "test"}
      sig = TwilioSignature.signature(@token, @url, params)
      assert TwilioSignature.valid?(@token, "  #{@url}  ", params, sig) == true
    end

    test "trims whitespace from provided signature before validating" do
      params = %{"Body" => "test"}
      sig = TwilioSignature.signature(@token, @url, params)
      assert TwilioSignature.valid?(@token, @url, params, "  #{sig}  ") == true
    end
  end

  # ---------------------------------------------------------------------------
  # Constant-time secure_compare (exercised indirectly through valid?/4)
  # ---------------------------------------------------------------------------
  describe "secure_compare via valid?/4" do
    test "rejects signatures of different lengths" do
      # Produce a valid signature, then append an extra character to change length
      params = %{"Body" => "test"}
      sig = TwilioSignature.signature(@token, @url, params)
      longer_sig = sig <> "A"
      assert TwilioSignature.valid?(@token, @url, params, longer_sig) == false
    end

    test "rejects truncated signatures" do
      params = %{"Body" => "test"}
      sig = TwilioSignature.signature(@token, @url, params)
      truncated = String.slice(sig, 0..(String.length(sig) - 3)//1)
      assert TwilioSignature.valid?(@token, @url, params, truncated) == false
    end

    test "rejects signature with single bit difference" do
      params = %{"Body" => "test"}
      sig = TwilioSignature.signature(@token, @url, params)

      # Flip one character in the signature
      <<first_byte, rest::binary>> = sig
      flipped = <<Bitwise.bxor(first_byte, 1), rest::binary>>
      assert TwilioSignature.valid?(@token, @url, params, flipped) == false
    end

    test "two empty strings would match but valid? rejects empty provided" do
      # Even though secure_compare("", "") would be true, valid? rejects empty
      assert TwilioSignature.valid?(@token, @url, %{}, "") == false
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-verification: signature/3 output matches manual :crypto.mac
  # ---------------------------------------------------------------------------
  describe "cross-verification with :crypto.mac" do
    test "signature matches independent HMAC-SHA1 computation with params" do
      params = %{
        "AccountSid" => "ACtest123",
        "Body" => "Your code is 999999",
        "From" => "+15551230100",
        "MessageSid" => "SMabc",
        "To" => "+15551239999"
      }

      # Build the canonical param string manually, sorted by key
      param_str =
        "AccountSidACtest123" <>
          "BodyYour code is 999999" <>
          "From+15551230100" <>
          "MessageSidSMabc" <>
          "To+15551239999"

      data = @url <> param_str
      mac = :crypto.mac(:hmac, :sha, @token, data)
      expected = Base.encode64(mac)

      assert TwilioSignature.signature(@token, @url, params) == expected
    end

    test "signature matches independent HMAC-SHA1 with no params" do
      mac = :crypto.mac(:hmac, :sha, @token, @url)
      expected = Base.encode64(mac)
      assert TwilioSignature.signature(@token, @url, %{}) == expected
    end

    test "full round-trip: compute independently, validate with valid?" do
      params = %{"Body" => "verify me", "From" => "+10000000000"}
      param_str = "Bodyverify me" <> "From+10000000000"
      data = @url <> param_str
      mac = :crypto.mac(:hmac, :sha, @token, data)
      sig = Base.encode64(mac)

      assert TwilioSignature.valid?(@token, @url, params, sig) == true
    end

    test "independently computed signature fails when params differ" do
      # Compute signature for one set of params
      data = @url <> "BodyAAAA"
      mac = :crypto.mac(:hmac, :sha, @token, data)
      sig = Base.encode64(mac)

      # Validate against different params
      assert TwilioSignature.valid?(@token, @url, %{"Body" => "BBBB"}, sig) == false
    end
  end
end
