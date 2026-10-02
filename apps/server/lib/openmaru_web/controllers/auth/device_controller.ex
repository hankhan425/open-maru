defmodule OpenmaruWeb.Auth.DeviceController do
  @moduledoc """
  Device login for the CLI (SPEC-07 §1, SPEC-09 §1; `Openmaru.Accounts.Device`).

  `code` starts a login and `token` is polled by the CLI (both public); `approve` is
  called by the web app for a signed-in person (session only). Poll errors are 400s with
  the RFC 8628 codes `authorization_pending`, `slow_down`, `expired_token`,
  `access_denied` and `invalid_grant`.
  """

  use OpenmaruWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Openmaru.Accounts.Device
  alias Openmaru.Error
  alias OpenmaruWeb.Auth.{Schemas, TokenJSON}
  alias OpenmaruWeb.Plugs.{Idempotency, Session}
  alias OpenmaruWeb.Schemas.ErrorResponse

  action_fallback OpenmaruWeb.FallbackController

  tags(["auth"])

  operation(:code,
    summary: "Start a device login",
    description:
      "Show `user_code` and `verification_uri` to the person, then poll `/auth/device/token`.",
    responses: [ok: {"The codes", "application/json", Schemas.DeviceAuthorization}]
  )

  @doc false
  def code(conn, _params) do
    {:ok, authorization} = Device.start(Session.client_meta(conn))
    verification_uri = Application.fetch_env!(:openmaru, :web_url) <> "/device"

    json(
      conn,
      Map.merge(authorization, %{
        verification_uri: verification_uri,
        verification_uri_complete:
          verification_uri <> "?" <> URI.encode_query(user_code: authorization.user_code)
      })
    )
  end

  operation(:token,
    summary: "Poll a device login",
    description:
      "Every 5 seconds at most. Once approved, returns a new personal access token named " <>
        "`CLI (<user agent>)`; the device code is then used up.",
    request_body: {"The device code", "application/json", Schemas.DeviceTokenRequest},
    responses: [
      ok: {"The new token", "application/json", Schemas.NewPersonalAccessToken},
      bad_request:
        {"authorization_pending, slow_down, expired_token, access_denied, invalid_grant, or invalid_request",
         "application/json", ErrorResponse}
    ]
  )

  @doc false
  def token(conn, params) do
    with {:ok, device_code} <- fetch_string(params, "device_code"),
         {:ok, token, pat} <- Device.poll(device_code, Session.client_meta(conn)) do
      conn
      |> Idempotency.skip_store()
      |> json(TokenJSON.new_pat(pat, token))
    end
  end

  operation(:approve,
    summary: "Approve or deny a device login",
    description: "For the signed-in person (session cookie and `x-csrf-token`).",
    request_body: {"The user code", "application/json", Schemas.DeviceApproval},
    responses: [
      ok: {"The decision", "application/json", Schemas.DeviceApprovalResult},
      bad_request:
        {"expired_token, invalid_grant (already decided), or invalid_request", "application/json",
         ErrorResponse},
      not_found: {"Unknown user code", "application/json", ErrorResponse},
      unprocessable_entity: {"Unknown decision", "application/json", ErrorResponse},
      unauthorized: {"Not signed in", "application/json", ErrorResponse},
      forbidden: {"Not a web session, or bad CSRF token", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def approve(conn, params) do
    user = conn.assigns.current_user
    meta = Session.client_meta(conn)

    with {:ok, decide} <- decision(params["decision"]),
         {:ok, user_code} <- fetch_user_code(params),
         {:ok, status} <- decide.(user, user_code, meta) do
      json(conn, %{status: status})
    end
  end

  defp decision(nil), do: decision("approve")

  defp decision("approve"),
    do: {:ok, &with_status(Device.approve(&1, &2, &3), "approved")}

  defp decision("deny"), do: {:ok, &with_status(Device.deny(&1, &2, &3), "denied")}

  defp decision(_other) do
    {:error,
     Error.new(:validation_failed, "Unknown decision", %{
       fields: %{decision: ["must be approve or deny"]}
     })}
  end

  defp with_status(:ok, status), do: {:ok, status}
  defp with_status({:error, _} = error, _status), do: error

  # Any string reaches the lookup (malformed codes are unknown, 404); a missing one is 400.
  defp fetch_user_code(%{"user_code" => user_code}) when is_binary(user_code),
    do: {:ok, user_code}

  defp fetch_user_code(_params),
    do: {:error, Error.new(:invalid_request, "user_code is required")}

  defp fetch_string(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:invalid_request, "#{key} is required")}
    end
  end
end
