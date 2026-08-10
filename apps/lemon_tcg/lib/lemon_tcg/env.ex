defmodule LemonTcg.Env do
  @moduledoc """
  Environment variables read by `lemon_tcg` — TCG market data and paper execution.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :magic_eden_api_key,
      env_var: "MAGIC_EDEN_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Magic Eden marketplace API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_tcg]
    },
    %{
      name: :opensea_api_key,
      env_var: "OPENSEA_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenSea marketplace API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_tcg]
    },
    %{
      name: :pricecharting_api_token,
      env_var: "PRICECHARTING_API_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "PriceCharting API token.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_tcg]
    },
    %{
      name: :evm_private_key,
      env_var: "EVM_PRIVATE_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "EVM wallet private key used to sign on-chain transactions.",
      secret?: true,
      required?: false,
      area: :tcg_wallet,
      apps: [:lemon_tcg]
    },
    %{
      name: :solana_keypair_file,
      env_var: "SOLANA_KEYPAIR_FILE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Path to a Solana keypair JSON file used to sign wallet transactions.",
      secret?: true,
      required?: false,
      area: :tcg_wallet,
      apps: [:lemon_tcg]
    },
    %{
      name: :solana_secret_key,
      env_var: "SOLANA_SECRET_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Base58/array-encoded Solana secret key used to sign wallet transactions.",
      secret?: true,
      required?: false,
      area: :tcg_wallet,
      apps: [:lemon_tcg]
    }
  ]
end
