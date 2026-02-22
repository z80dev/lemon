ExUnit.start()

defmodule MarketIntel.Ingestion.HttpClientBehaviour do
  @callback get(String.t(), [{String.t(), String.t()}], keyword()) :: term()
  @callback post(String.t(), String.t(), [{String.t(), String.t()}], keyword()) :: term()
end

defmodule MarketIntel.Ingestion.SecretsBehaviour do
  @callback get(atom()) :: {:ok, String.t()} | {:error, term()}
end

Mox.defmock(MarketIntel.Ingestion.HttpClientMock, for: MarketIntel.Ingestion.HttpClientBehaviour)
Mox.defmock(HTTPoison.Mock, for: MarketIntel.Ingestion.HttpClientBehaviour)
Mox.defmock(MarketIntel.Secrets.Mock, for: MarketIntel.Ingestion.SecretsBehaviour)
