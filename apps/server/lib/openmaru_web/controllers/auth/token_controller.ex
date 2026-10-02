defmodule OpenmaruWeb.Auth.TokenController do
  @moduledoc """
  The signed-in user's personal access tokens (SPEC-07 §1, `/me/tokens`; session only).
  A new token's value is in the create response and nowhere else.
  """

  use OpenmaruWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Openmaru.Accounts.PAT
  alias Openmaru.{Error, TypeID}
  alias OpenmaruWeb.Auth.{Schemas, TokenJSON}
  alias OpenmaruWeb.Plugs.{Idempotency, Session}
  alias OpenmaruWeb.Schemas.ErrorResponse

  action_fallback OpenmaruWeb.FallbackController

  @default_limit 50
  @max_limit 100

  tags(["account"])

  operation(:index,
    summary: "Your personal access tokens",
    description: "Tokens that are not revoked, newest first. Never includes token values.",
    parameters: [
      cursor: [in: :query, type: :string, description: "`next_cursor` of the previous page"],
      limit: [in: :query, type: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 100}]
    ],
    responses: [
      ok: {"A page of tokens", "application/json", Schemas.PersonalAccessTokenList},
      bad_request: {"Bad cursor or limit", "application/json", ErrorResponse},
      unauthorized: {"Not signed in", "application/json", ErrorResponse},
      forbidden: {"Not a web session", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def index(conn, params) do
    with {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, before} <- parse_cursor(params["cursor"]) do
      {page, rest} =
        conn.assigns.current_user
        |> PAT.list(limit: limit + 1, before: before)
        |> Enum.split(limit)

      next_cursor = if rest != [], do: TypeID.encode("pat", List.last(page).id)
      json(conn, %{data: Enum.map(page, &TokenJSON.pat/1), next_cursor: next_cursor})
    end
  end

  operation(:create,
    summary: "Create a personal access token",
    description:
      "The response is the only place the token appears. Requires `x-csrf-token`. " <>
        "An `Idempotency-Key` is accepted but the response is not kept for replays.",
    request_body: {"The token", "application/json", Schemas.CreatePersonalAccessToken},
    responses: [
      created: {"The token, with its value", "application/json", Schemas.NewPersonalAccessToken},
      unprocessable_entity: {"Missing name or bad ttl_days", "application/json", ErrorResponse},
      unauthorized: {"Not signed in", "application/json", ErrorResponse},
      forbidden: {"Not a web session, or bad CSRF token", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def create(conn, params) do
    attrs = Map.take(params, ["name", "ttl_days"])

    with {:ok, token, pat} <-
           PAT.create(conn.assigns.current_user, attrs, Session.client_meta(conn)) do
      conn
      |> Idempotency.skip_store()
      |> put_status(:created)
      |> json(TokenJSON.new_pat(pat, token))
    end
  end

  operation(:delete,
    summary: "Revoke a personal access token",
    description: "It stops working immediately. Requires `x-csrf-token`.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Revoked",
      not_found: {"No such token of yours", "application/json", ErrorResponse},
      unauthorized: {"Not signed in", "application/json", ErrorResponse},
      forbidden: {"Not a web session, or bad CSRF token", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def delete(conn, %{"id" => id}) do
    with {:ok, uuid} <- decode_id(id),
         :ok <- PAT.revoke(conn.assigns.current_user, uuid, Session.client_meta(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  defp decode_id(id) do
    case TypeID.decode(id, "pat") do
      {:ok, uuid} -> {:ok, uuid}
      {:error, :invalid_id} -> {:error, Error.new(:not_found, "Token not found")}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..@max_limit -> {:ok, limit}
      _ -> {:error, invalid_request("limit must be 1-#{@max_limit}")}
    end
  end

  defp parse_limit(_value), do: {:error, invalid_request("limit must be 1-#{@max_limit}")}

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(cursor) do
    case TypeID.decode(cursor, "pat") do
      {:ok, uuid} -> {:ok, uuid}
      {:error, :invalid_id} -> {:error, invalid_request("Invalid cursor")}
    end
  end

  defp invalid_request(message), do: Error.new(:invalid_request, message)
end
