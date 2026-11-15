defmodule LemonCore.EgressBroker.CertificatesTest do
  use ExUnit.Case, async: true

  alias LemonCore.EgressBroker.Certificates

  require Record

  for {name, tag} <- [
        rsa_private_key: :RSAPrivateKey,
        rsa_public_key: :RSAPublicKey,
        otp_certificate: :OTPCertificate,
        tbs_certificate: :OTPTBSCertificate,
        public_key_info: :OTPSubjectPublicKeyInfo,
        signature_algorithm: :SignatureAlgorithm,
        validity: :Validity,
        extension: :Extension,
        basic_constraints: :BasicConstraints,
        authority_key_identifier: :AuthorityKeyIdentifier
      ] do
    Record.defrecordp(
      name,
      tag,
      Record.extract(tag, from_lib: "public_key/include/public_key.hrl")
    )
  end

  @host "api.example.test"
  @basic_constraints {2, 5, 29, 19}
  @key_usage {2, 5, 29, 15}
  @subject_key_identifier {2, 5, 29, 14}
  @authority_key_identifier {2, 5, 29, 35}
  @subject_alt_name {2, 5, 29, 17}
  @extended_key_usage {2, 5, 29, 37}
  @server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @sha256_with_rsa {1, 2, 840, 113_549, 1, 1, 11}

  setup_all do
    started_at = System.system_time(:second)
    ca = Certificates.create()
    leaf = Certificates.leaf(ca, @host)
    finished_at = System.system_time(:second)

    {:ok, ca: ca, leaf: leaf, started_at: started_at, finished_at: finished_at}
  end

  test "concurrent callers share the boot CA without reusing independently created CAs", %{ca: ca} do
    owner = self()
    barrier = make_ref()

    tasks =
      for _ <- 1..16 do
        Task.async(fn ->
          send(owner, {:ready, barrier, self()})

          receive do
            {:start, ^barrier} -> Certificates.boot().cert
          after
            5_000 -> raise "certificate test barrier timed out"
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^barrier, ^pid}, 5_000
    end

    for task <- tasks, do: send(task.pid, {:start, barrier})

    assert [boot_cert] = tasks |> Enum.map(&Task.await(&1, 30_000)) |> Enum.uniq()
    assert Certificates.boot().cert == boot_cert
    refute ca.cert == boot_cert
    assert :public_key.pkix_is_self_signed(boot_cert)
  end

  test "public PEM contains exactly the CA certificate and no private key", %{ca: ca} do
    assert Enum.sort(Map.keys(ca)) == [:cert, :key, :pem]
    assert is_binary(ca.pem)
    assert [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(ca.pem)
    assert der == ca.cert
    refute ca.pem =~ "PRIVATE KEY"
    assert :public_key.pkix_is_self_signed(ca.cert)
    assert :public_key.pkix_verify(ca.cert, certificate_public_key(ca.cert))
  end

  test "CA and leaf have independent 2048-bit RSA keys and SHA-256 signatures", %{
    ca: ca,
    leaf: leaf
  } do
    refute ca.key == leaf.key
    assert Enum.sort(Map.keys(leaf)) == [:cert, :key]

    for certificate <- [ca, leaf] do
      key = certificate.key
      assert rsa_private_key(key, :publicExponent) == 65_537
      assert bit_size(:binary.encode_unsigned(rsa_private_key(key, :modulus))) == 2048
      public_key = certificate_public_key(certificate.cert)
      assert rsa_public_key(public_key, :modulus) == rsa_private_key(key, :modulus)
      assert rsa_public_key(public_key, :publicExponent) == rsa_private_key(key, :publicExponent)

      signature = :public_key.sign("broker certificate key proof", :sha256, key)
      assert :public_key.verify("broker certificate key proof", :sha256, signature, public_key)

      decoded = :public_key.pkix_decode_cert(certificate.cert, :otp)
      algorithm = otp_certificate(decoded, :signatureAlgorithm)
      assert signature_algorithm(algorithm, :algorithm) == @sha256_with_rsa
      assert signature_algorithm(algorithm, :parameters) == {:asn1_OPENTYPE, <<5, 0>>}
      assert tbs_certificate(tbs(certificate.cert), :signature) == algorithm
      assert tbs_certificate(tbs(certificate.cert), :version) == :v3
      serial = tbs_certificate(tbs(certificate.cert), :serialNumber)
      assert serial > 0
      assert byte_size(:binary.encode_unsigned(serial)) <= 20
    end
  end

  test "CA permits certificate signing but no subordinate CAs", %{ca: ca} do
    extensions = extensions(ca.cert)

    assert extension(critical: true, extnValue: basic_constraints(cA: true, pathLenConstraint: 0)) =
             Map.fetch!(extensions, @basic_constraints)

    assert extension(critical: true, extnValue: [:keyCertSign, :cRLSign]) =
             Map.fetch!(extensions, @key_usage)

    assert extension(critical: false, extnValue: identifier) =
             Map.fetch!(extensions, @subject_key_identifier)

    assert identifier ==
             :crypto.hash(
               :sha,
               :public_key.der_encode(:RSAPublicKey, certificate_public_key(ca.cert))
             )
  end

  test "leaf is restricted to TLS server authentication and one DNS SAN", %{ca: ca, leaf: leaf} do
    extensions = extensions(leaf.cert)

    assert extension(
             critical: true,
             extnValue: basic_constraints(cA: false, pathLenConstraint: :asn1_NOVALUE)
           ) = Map.fetch!(extensions, @basic_constraints)

    assert extension(critical: true, extnValue: [:digitalSignature, :keyEncipherment]) =
             Map.fetch!(extensions, @key_usage)

    assert extension(extnValue: [@server_auth]) = Map.fetch!(extensions, @extended_key_usage)

    assert extension(extnValue: [{:dNSName, ~c"api.example.test"}]) =
             Map.fetch!(extensions, @subject_alt_name)

    assert extension(extnValue: authority_key_identifier(keyIdentifier: authority_identifier)) =
             Map.fetch!(extensions, @authority_key_identifier)

    root_identifier = extensions(ca.cert) |> Map.fetch!(@subject_key_identifier)
    assert authority_identifier == extension(root_identifier, :extnValue)
    refute :public_key.pkix_is_self_signed(leaf.cert)
  end

  test "leaf chains to its CA and verifies only the exact hostname", %{ca: ca, leaf: leaf} do
    assert {:ok, _} = :public_key.pkix_path_validation(ca.cert, [leaf.cert], [])
    assert :public_key.pkix_verify(leaf.cert, certificate_public_key(ca.cert))
    assert tbs_certificate(tbs(leaf.cert), :issuer) == tbs_certificate(tbs(ca.cert), :subject)

    options = [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]

    assert :public_key.pkix_verify_hostname(
             leaf.cert,
             [dns_id: String.to_charlist(@host)],
             options
           )

    for host <- [
          "other.example.test",
          "example.test",
          "child.api.example.test",
          "api.example.test.evil"
        ] do
      refute :public_key.pkix_verify_hostname(
               leaf.cert,
               [dns_id: String.to_charlist(host)],
               options
             )
    end

    refute :public_key.pkix_verify_hostname(leaf.cert, [ip: {127, 0, 0, 1}], options)
  end

  test "fresh CAs do not trust a previous broker's leaves", %{ca: ca, leaf: leaf} do
    other_ca = Certificates.create()
    refute ca.cert == other_ca.cert
    refute ca.key == other_ca.key
    refute ca.pem == other_ca.pem
    refute :public_key.pkix_verify(leaf.cert, certificate_public_key(other_ca.cert))

    assert {:error, {:bad_cert, _}} =
             :public_key.pkix_path_validation(other_ca.cert, [leaf.cert], [])
  end

  test "each leaf has a fresh key and serial even for the same hostname", %{ca: ca, leaf: leaf} do
    other_leaf = Certificates.leaf(ca, @host)
    refute leaf.key == other_leaf.key
    refute leaf.cert == other_leaf.cert

    refute tbs_certificate(tbs(leaf.cert), :serialNumber) ==
             tbs_certificate(tbs(other_leaf.cert), :serialNumber)

    assert {:ok, _} = :public_key.pkix_path_validation(ca.cert, [other_leaf.cert], [])
  end

  test "CA lasts ten years while leaves last one day with clock-skew allowance", %{
    ca: ca,
    leaf: leaf,
    started_at: started_at,
    finished_at: finished_at
  } do
    ca_validity = tbs_certificate(tbs(ca.cert), :validity)
    leaf_validity = tbs_certificate(tbs(leaf.cert), :validity)
    ca_not_before = ca_validity |> validity(:notBefore) |> unix_time()
    ca_not_after = ca_validity |> validity(:notAfter) |> unix_time()
    leaf_not_before = leaf_validity |> validity(:notBefore) |> unix_time()
    leaf_not_after = leaf_validity |> validity(:notAfter) |> unix_time()
    ten_years = 3650 * 86_400

    assert ca_not_before >= started_at - 300
    assert ca_not_before <= finished_at - 300
    assert ca_not_after >= started_at + ten_years
    assert ca_not_after <= finished_at + ten_years
    assert ca_not_after - ca_not_before == ten_years + 300
    assert leaf_not_before >= started_at - 300
    assert leaf_not_before <= finished_at - 300
    assert leaf_not_after >= started_at + 86_400
    assert leaf_not_after <= finished_at + 86_400
    assert leaf_not_after - leaf_not_before == 86_700
    assert leaf_not_before >= ca_not_before
    assert leaf_not_after <= ca_not_after
  end

  test "a later-issued leaf is fresh but cannot outlive a nearly expired CA", %{ca: ca} do
    now = System.system_time(:second)
    expires_at = now + 3600

    ca_validity =
      validity(
        notBefore: encoded_time(now - 7 * 86_400),
        notAfter: encoded_time(expires_at)
      )

    ca_tbs = tbs_certificate(tbs(ca.cert), validity: ca_validity)
    ca_cert = :public_key.pkix_sign(ca_tbs, ca.key)

    limited_ca = %{
      cert: ca_cert,
      key: ca.key,
      pem: :public_key.pem_encode([{:Certificate, ca_cert, :not_encrypted}])
    }

    leaf = Certificates.leaf(limited_ca, @host)
    leaf_validity = tbs_certificate(tbs(leaf.cert), :validity)
    assert leaf_validity |> validity(:notBefore) |> unix_time() >= now - 300
    assert leaf_validity |> validity(:notAfter) |> unix_time() == expires_at
    assert {:ok, _} = :public_key.pkix_path_validation(ca_cert, [leaf.cert], [])
  end

  defp tbs(cert) do
    cert |> :public_key.pkix_decode_cert(:otp) |> otp_certificate(:tbsCertificate)
  end

  defp certificate_public_key(cert) do
    cert |> tbs() |> tbs_certificate(:subjectPublicKeyInfo) |> public_key_info(:subjectPublicKey)
  end

  defp extensions(cert) do
    cert |> tbs() |> tbs_certificate(:extensions) |> Map.new(&{extension(&1, :extnID), &1})
  end

  defp encoded_time(seconds) do
    datetime = DateTime.from_unix!(seconds)

    if datetime.year >= 1950 and datetime.year < 2050 do
      {:utcTime, datetime |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()}
    else
      {:generalTime, datetime |> Calendar.strftime("%Y%m%d%H%M%SZ") |> String.to_charlist()}
    end
  end

  defp unix_time({:utcTime, time}) do
    <<year::binary-size(2), _rest::binary>> = value = List.to_string(time)
    century = if String.to_integer(year) < 50, do: "20", else: "19"
    unix_time({:generalTime, String.to_charlist(century <> value)})
  end

  defp unix_time({:generalTime, time}) do
    <<year::binary-size(4), month::binary-size(2), day::binary-size(2), hour::binary-size(2),
      minute::binary-size(2), second::binary-size(2), "Z">> = List.to_string(time)

    date = {String.to_integer(year), String.to_integer(month), String.to_integer(day)}
    clock = {String.to_integer(hour), String.to_integer(minute), String.to_integer(second)}

    :calendar.datetime_to_gregorian_seconds({date, clock}) -
      :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
  end
end
