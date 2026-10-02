defmodule OpenmaruWeb.Auth.Schemas do
  @moduledoc "OpenAPI schemas for the auth and account endpoints (C01, C02)."

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

  defmodule PersonalAccessToken do
    @moduledoc "A personal access token as listed: never its value."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PersonalAccessToken",
      type: :object,
      required: [:id, :name, :last4, :created_at, :last_used_at, :expires_at],
      properties: %{
        id: %Schema{type: :string, pattern: ~S"^pat_[0-9a-z]{26}$"},
        name: %Schema{type: :string, maxLength: 100},
        last4: %Schema{type: :string, minLength: 4, maxLength: 4},
        created_at: %Schema{type: :string, format: :"date-time"},
        last_used_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Updated at most once a minute"
        },
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true}
      }
    })
  end

  defmodule NewPersonalAccessToken do
    @moduledoc "A personal access token just created, with its value."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "NewPersonalAccessToken",
      type: :object,
      required: [:id, :name, :last4, :created_at, :last_used_at, :expires_at, :token],
      properties:
        Map.put(PersonalAccessToken.schema().properties, :token, %Schema{
          type: :string,
          pattern: ~S"^om_pat_[A-Za-z0-9_-]{43}$",
          description: "Shown only in this response; send as `Authorization: Bearer <token>`"
        })
    })
  end

  defmodule PersonalAccessTokenList do
    @moduledoc "A page of personal access tokens, newest first."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PersonalAccessTokenList",
      type: :object,
      required: [:data, :next_cursor],
      properties: %{
        data: %Schema{type: :array, items: PersonalAccessToken},
        next_cursor: %Schema{
          type: :string,
          nullable: true,
          description: "Pass as `cursor` for the next page; null on the last page"
        }
      }
    })
  end

  defmodule CreatePersonalAccessToken do
    @moduledoc "`POST /me/tokens` body."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CreatePersonalAccessToken",
      type: :object,
      required: [:name],
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 100},
        ttl_days: %Schema{
          type: :integer,
          minimum: 1,
          maximum: 365,
          description: "Days until the token expires; omit for no expiry"
        }
      }
    })
  end

  defmodule DeviceAuthorization do
    @moduledoc "A started device login (RFC 8628 §3.2)."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceAuthorization",
      type: :object,
      required: [
        :device_code,
        :user_code,
        :verification_uri,
        :verification_uri_complete,
        :expires_in,
        :interval
      ],
      properties: %{
        device_code: %Schema{type: :string, description: "Poll `/auth/device/token` with it"},
        user_code: %Schema{
          type: :string,
          pattern: ~S"^[BCDFGHJKLMNPQRSTVWXZ2-9]{4}-[BCDFGHJKLMNPQRSTVWXZ2-9]{4}$",
          description: "Shown to the person, who enters it at `verification_uri`"
        },
        verification_uri: %Schema{type: :string, format: :uri},
        verification_uri_complete: %Schema{
          type: :string,
          format: :uri,
          description: "`verification_uri` with the user code filled in"
        },
        expires_in: %Schema{type: :integer, description: "Seconds (600)"},
        interval: %Schema{type: :integer, description: "Seconds between polls (5)"}
      }
    })
  end

  defmodule DeviceTokenRequest do
    @moduledoc "`POST /auth/device/token` body."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceTokenRequest",
      type: :object,
      required: [:device_code],
      properties: %{device_code: %Schema{type: :string}}
    })
  end

  defmodule DeviceApproval do
    @moduledoc "`POST /auth/device/approve` body."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceApproval",
      type: :object,
      required: [:user_code],
      properties: %{
        user_code: %Schema{
          type: :string,
          description: "As shown by the CLI; case, spaces and the hyphen are ignored"
        },
        decision: %Schema{type: :string, enum: ["approve", "deny"], default: "approve"}
      }
    })
  end

  defmodule DeviceApprovalResult do
    @moduledoc "The outcome of `POST /auth/device/approve`."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceApprovalResult",
      type: :object,
      required: [:status],
      properties: %{status: %Schema{type: :string, enum: ["approved", "denied"]}}
    })
  end

  defmodule SocketToken do
    @moduledoc "A short-lived token for the realtime socket."
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SocketToken",
      type: :object,
      required: [:token, :expires_in],
      properties: %{
        token: %Schema{type: :string, description: "Pass as the socket's `token` param"},
        expires_in: %Schema{type: :integer, description: "Seconds (300)"}
      }
    })
  end
end
