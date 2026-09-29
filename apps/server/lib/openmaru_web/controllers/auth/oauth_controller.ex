defmodule OpenmaruWeb.Auth.OAuthController do
  @moduledoc """
  GitHub and Google sign-in (SPEC-07 §1, SPEC-09 §1).

  `request` redirects to the provider and sets the `_om_oauth` cookie (the id of the
  server-side state, 5 minutes). The provider sends the browser back to `callback`,
  which signs in, registers or links (see `Openmaru.Accounts.oauth_callback/3`).

  Browsers are redirected to the web app: `/` on success, `/signin?error=<code>` on
  failure. Clients that accept only JSON get the user or the error envelope.
  """

  use OpenmaruWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Openmaru.{Accounts, Error}
  alias OpenmaruWeb.Auth.{Schemas, UserJSON}
  alias OpenmaruWeb.FallbackController
  alias OpenmaruWeb.Plugs.Session
  alias OpenmaruWeb.Schemas.ErrorResponse

  @state_cookie "_om_oauth"
  @state_cookie_opts [
    http_only: true,
    secure: true,
    same_site: "Lax",
    path: "/api/v1/auth/oauth"
  ]

  tags(["auth"])

  @provider_param [
    provider: [
      in: :path,
      type: %OpenApiSpex.Schema{type: :string, enum: ["github", "google"]},
      required: true
    ]
  ]

  operation(:request,
    summary: "Start an OAuth sign-in",
    parameters: @provider_param,
    responses: [
      found: "Redirect to the provider",
      not_found: {"Unknown or disabled provider", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def request(conn, %{"provider" => provider}) do
    case Accounts.begin_oauth(provider, callback_url(provider)) do
      {:ok, %{url: url, state_id: state_id}} ->
        conn
        |> put_resp_cookie(@state_cookie, state_id, [max_age: 300] ++ @state_cookie_opts)
        |> redirect(external: url)

      {:error, %Error{} = error} ->
        FallbackController.call(conn, {:error, error})
    end
  end

  operation(:callback,
    summary: "OAuth callback",
    description:
      "Browsers are redirected to the web app (`/` or `/signin?error=<code>`); JSON clients get the user.",
    parameters: @provider_param,
    responses: [
      ok: {"The user", "application/json", Schemas.User},
      found: "Redirect to the web app",
      bad_request: {"Invalid state or provider failure", "application/json", ErrorResponse},
      forbidden: {"Suspended, or linking an unverified email", "application/json", ErrorResponse},
      conflict: {"account_exists", "application/json", ErrorResponse}
    ]
  )

  @doc false
  def callback(conn, %{"provider" => provider} = params) do
    conn = fetch_cookies(conn)
    current_user = conn.assigns[:current_user]

    result =
      Accounts.oauth_callback(provider, Map.delete(params, "provider"),
        state_id: conn.cookies[@state_cookie],
        redirect_uri: callback_url(provider),
        current_user: current_user,
        meta: Session.client_meta(conn)
      )

    conn = delete_resp_cookie(conn, @state_cookie, @state_cookie_opts)

    case result do
      {:ok, {:linked, user}} -> respond(conn, user)
      {:ok, {_signed_in, user}} -> conn |> Session.sign_in(user) |> respond(user)
      {:error, %Error{} = error} -> respond_error(conn, error)
    end
  end

  defp respond(conn, user) do
    if browser?(conn),
      do: redirect(conn, external: web_url() <> "/"),
      else: json(conn, UserJSON.user(user, user))
  end

  defp respond_error(conn, %Error{code: code} = error) do
    if browser?(conn),
      do: redirect(conn, external: web_url() <> "/signin?" <> URI.encode_query(error: code)),
      else: FallbackController.call(conn, {:error, error})
  end

  defp browser?(conn), do: get_format(conn) == "html"

  defp callback_url(provider), do: url(~p"/api/v1/auth/oauth/#{provider}/callback")

  defp web_url, do: Application.fetch_env!(:openmaru, :web_url)
end
