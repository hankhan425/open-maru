defmodule OpenmaruWeb.Auth.Schemas do
  @moduledoc "OpenAPI schemas for the auth and account endpoints (C01)."

  alias OpenApiSpex.Schema

  defmodule User do
    @moduledoc "A user. `email` and `platform_role` appear only for the user themself."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "User",
      type: :object,
      required: [:id, :handle, :display_name, :created_at],
      properties: %{
        id: %Schema{type: :string, pattern: ~S"^usr_[0-9a-z]{26}$"},
        handle: %Schema{type: :string, nullable: true, pattern: ~S"^[a-z0-9][a-z0-9_-]{1,29}$"},
        display_name: %Schema{type: :string, nullable: true},
        created_at: %Schema{type: :string, format: :"date-time"},
        email: %Schema{type: :string, nullable: true, description: "Own user only"},
        platform_role: %Schema{
          type: :string,
          enum: ["user", "admin"],
          description: "Own user only"
        }
      }
    })
  end

  defmodule UpdateMe do
    @moduledoc "`PATCH /me` body."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UpdateMe",
      type: :object,
      properties: %{
        handle: %Schema{
          type: :string,
          description: "Set once; lower-cased; `^[a-z0-9][a-z0-9_-]{1,29}$`; not reserved"
        },
        display_name: %Schema{type: :string, maxLength: 80, nullable: true}
      }
    })
  end

  defmodule PasskeyOptions do
    @moduledoc "A started WebAuthn ceremony."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasskeyOptions",
      type: :object,
      required: [:challenge_id, :public_key],
      properties: %{
        challenge_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Send back when finishing"
        },
        public_key: %Schema{
          type: :object,
          additionalProperties: true,
          description:
            "W3C PublicKeyCredentialCreationOptionsJSON or PublicKeyCredentialRequestOptionsJSON"
        }
      }
    })
  end

  defmodule PasskeyCredential do
    @moduledoc "A finished WebAuthn ceremony."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasskeyCredential",
      type: :object,
      required: [:challenge_id, :credential],
      properties: %{
        challenge_id: %Schema{type: :string, format: :uuid},
        credential: %Schema{
          type: :object,
          additionalProperties: true,
          description: "W3C RegistrationResponseJSON or AuthenticationResponseJSON"
        }
      }
    })
  end

  defmodule CsrfToken do
    @moduledoc "The session's CSRF token."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CsrfToken",
      type: :object,
      required: [:csrf_token],
      properties: %{
        csrf_token: %Schema{type: :string, description: "Send as `x-csrf-token` on mutations"}
      }
    })
  end
end
