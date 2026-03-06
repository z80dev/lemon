defmodule LemonGateway.Transports.Webhook.SignatureValidation do
  @moduledoc """
  Authorization and signature validation for webhook requests.
  """

  alias LemonGateway.Transports.Webhook.Request

  @spec authorize_request(Plug.Conn.t(), map(), map(), map()) :: :ok | {:error, term()}
  def authorize_request(conn, payload, integration, webhook_config) do
    Request.authorize_request(conn, payload, integration, webhook_config)
  end
end
