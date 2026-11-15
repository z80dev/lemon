defmodule LemonCore.EgressBroker.Certificates do
  @moduledoc """
  Ephemeral RSA certificates for the egress broker.

  `boot/0` lazily shares one self-signed CA for the current VM lifetime; merely
  starting Lemon does not generate keys. `create/0` always creates an independent
  CA, including for local upstream test fixtures. CA validity is ten years
  (3650 days); the trust scope is the VM lifetime, not a daily expiration.
  Leaves are valid for 24 hours from issuance, bounded by the CA's validity.
  Both allow five minutes of clock skew before creation. The broker must
  supply an exact DNS hostname already validated against its trusted allowlist.

  Private keys are returned as OTP records for in-memory TLS configuration;
  this module never writes files or serializes private keys. Only the CA's
  public certificate is included in `:pem`.
  """

  require Record

  for {name, tag} <- [
        rsa_private_key: :RSAPrivateKey,
        rsa_public_key: :RSAPublicKey,
        otp_certificate: :OTPCertificate,
        tbs_certificate: :OTPTBSCertificate,
        public_key_info: :OTPSubjectPublicKeyInfo,
        public_key_algorithm: :PublicKeyAlgorithm,
        signature_algorithm: :SignatureAlgorithm,
        attribute: :AttributeTypeAndValue,
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

  @rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}
  @sha256_with_rsa {1, 2, 840, 113_549, 1, 1, 11}
  @common_name {2, 5, 4, 3}
  @basic_constraints {2, 5, 29, 19}
  @key_usage {2, 5, 29, 15}
  @subject_key_identifier {2, 5, 29, 14}
  @authority_key_identifier {2, 5, 29, 35}
  @subject_alt_name {2, 5, 29, 17}
  @extended_key_usage {2, 5, 29, 37}
  @server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @ca_lifetime_seconds 10 * 365 * 24 * 60 * 60
  @leaf_lifetime_seconds 24 * 60 * 60
  @clock_skew_seconds 5 * 60
  @boot_ca_key {__MODULE__, :boot_ca}

  @type certificate :: %{cert: binary(), key: tuple()}
  @type ca :: %{cert: binary(), key: tuple(), pem: binary()}

  @doc "Lazily returns the VM-local CA shared by all egress brokers."
  @spec boot() :: ca()
  def boot do
    case :persistent_term.get(@boot_ca_key, nil) do
      nil ->
        :global.trans(
          {@boot_ca_key, self()},
          fn ->
            case :persistent_term.get(@boot_ca_key, nil) do
              nil ->
                ca = create()
                :persistent_term.put(@boot_ca_key, ca)
                ca

              ca ->
                ca
            end
          end,
          [node()]
        )

      ca ->
        ca
    end
  end

  @doc "Creates a fresh CA and its public-only PEM trust anchor."
  @spec create() :: ca()
  def create do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    public_key = public_key(key)
    subject = name("Lemon ephemeral egress CA")
    now = System.system_time(:second)

    validity =
      validity(
        notBefore: asn1_time(now - @clock_skew_seconds),
        notAfter: asn1_time(now + @ca_lifetime_seconds)
      )

    extensions = [
      extension(
        extnID: @basic_constraints,
        critical: true,
        extnValue: basic_constraints(cA: true, pathLenConstraint: 0)
      ),
      extension(extnID: @key_usage, critical: true, extnValue: [:keyCertSign, :cRLSign]),
      extension(
        extnID: @subject_key_identifier,
        critical: false,
        extnValue: key_identifier(public_key)
      )
    ]

    cert = sign(subject, subject, public_key, validity, extensions, key)
    %{cert: cert, key: key, pem: :public_key.pem_encode([{:Certificate, cert, :not_encrypted}])}
  end

  @doc "Signs a server-only leaf with one DNS SAN using this broker's CA."
  @spec leaf(ca(), String.t()) :: certificate()
  def leaf(%{cert: ca_cert, key: ca_key}, host) when is_binary(host) and byte_size(host) > 0 do
    ca_tbs = ca_cert |> :public_key.pkix_decode_cert(:otp) |> otp_certificate(:tbsCertificate)
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    public_key = public_key(key)

    extensions = [
      extension(
        extnID: @basic_constraints,
        critical: true,
        extnValue: basic_constraints(cA: false)
      ),
      extension(
        extnID: @key_usage,
        critical: true,
        extnValue: [:digitalSignature, :keyEncipherment]
      ),
      extension(extnID: @extended_key_usage, critical: false, extnValue: [@server_auth]),
      extension(
        extnID: @subject_alt_name,
        critical: false,
        extnValue: [{:dNSName, String.to_charlist(host)}]
      ),
      extension(
        extnID: @subject_key_identifier,
        critical: false,
        extnValue: key_identifier(public_key)
      ),
      extension(
        extnID: @authority_key_identifier,
        critical: false,
        extnValue: authority_key_identifier(keyIdentifier: key_identifier(public_key(ca_key)))
      )
    ]

    cert =
      sign(
        tbs_certificate(ca_tbs, :subject),
        name("Lemon egress proxy"),
        public_key,
        leaf_validity(tbs_certificate(ca_tbs, :validity)),
        extensions,
        ca_key
      )

    %{cert: cert, key: key}
  end

  defp sign(issuer, subject, public_key, validity, extensions, key) do
    tbs =
      tbs_certificate(
        version: :v3,
        serialNumber: :binary.decode_unsigned(:crypto.strong_rand_bytes(16)) + 1,
        # SHA-256/RSA is an open-type OID in OTP-PKIX's signature schema.
        # Supply the DER NULL, not the :NULL value used by the RSA SPKI schema.
        signature:
          signature_algorithm(
            algorithm: @sha256_with_rsa,
            parameters: {:asn1_OPENTYPE, <<5, 0>>}
          ),
        issuer: issuer,
        subject: subject,
        validity: validity,
        subjectPublicKeyInfo:
          public_key_info(
            algorithm: public_key_algorithm(algorithm: @rsa_encryption, parameters: :NULL),
            subjectPublicKey: public_key
          ),
        extensions: extensions
      )

    :public_key.pkix_sign(tbs, key)
  end

  defp public_key(key) do
    rsa_public_key(
      modulus: rsa_private_key(key, :modulus),
      publicExponent: rsa_private_key(key, :publicExponent)
    )
  end

  defp name(common_name) do
    {:rdnSequence, [[attribute(type: @common_name, value: {:utf8String, common_name})]]}
  end

  defp key_identifier(public_key) do
    # RFC 5280's SHA-1 key identifier is not a certificate signature.
    :crypto.hash(:sha, :public_key.der_encode(:RSAPublicKey, public_key))
  end

  defp leaf_validity(ca_validity) do
    now = System.system_time(:second)
    not_before = asn1_time(now - @clock_skew_seconds)
    not_after = asn1_time(now + @leaf_lifetime_seconds)
    ca_not_before = validity(ca_validity, :notBefore)
    ca_not_after = validity(ca_validity, :notAfter)

    validity(
      notBefore:
        if(time_key(not_before) < time_key(ca_not_before), do: ca_not_before, else: not_before),
      notAfter:
        if(time_key(not_after) > time_key(ca_not_after), do: ca_not_after, else: not_after)
    )
  end

  # Canonical UTC timestamps sort chronologically even across the UTCTime cutoff.
  defp time_key({:utcTime, [year_tens | _] = time}) when year_tens >= ?5, do: ~c"19" ++ time
  defp time_key({:utcTime, time}), do: ~c"20" ++ time
  defp time_key({:generalTime, time}), do: time

  defp asn1_time(seconds) do
    datetime = DateTime.from_unix!(seconds)

    if datetime.year >= 1950 and datetime.year < 2050 do
      {:utcTime, datetime |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()}
    else
      {:generalTime, datetime |> Calendar.strftime("%Y%m%d%H%M%SZ") |> String.to_charlist()}
    end
  end
end
