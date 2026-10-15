defmodule LemonControlPlane.ImageInputs do
  @moduledoc """
  Validates RPC image arrays using the shared native image-content wire contract.

  Accepts at most five PNG, JPEG, GIF or WebP images totaling at most 10 MiB
  decoded. Entries require string keys `type`, `mime_type` and `data`, type
  `image`, and canonical standard Base64 matching the MIME header. Successful
  values are `LemonAi.Types.ImageContent` structs; extra fields are discarded.
  """

  @type validation_error :: LemonAi.ImageInputs.validation_error()

  @spec validate(term()) ::
          {:ok, [LemonAi.Types.ImageContent.t()]} | {:error, validation_error()}
  defdelegate validate(images), to: LemonAi.ImageInputs
end
