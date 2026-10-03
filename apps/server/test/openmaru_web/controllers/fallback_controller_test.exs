defmodule OpenmaruWeb.FallbackControllerTest do
  use OpenmaruWeb.ConnCase, async: true

  alias Openmaru.Error
  alias OpenmaruWeb.FallbackController

  # SPEC-07 §2, copied verbatim so the implementation's table cannot drift unnoticed.
  @spec_codes [
    unauthenticated: 401,
    invalid_token: 401,
    forbidden: 403,
    not_steward: 403,
    not_operator: 403,
    not_admin: 403,
    no_mandate: 403,
    category_not_permitted: 403,
    capability_missing: 403,
    mandate_expired: 403,
    mandate_revoked: 403,
    per_request_exceeded: 403,
    approval_required: 403,
    not_eligible: 403,
    not_claimant: 403,
    self_review_forbidden: 403,
    budget_exceeded: 402,
    goal_funds_insufficient: 402,
    goal_paused: 423,
    not_found: 404,
    invalid_request: 400,
    validation_failed: 422,
    goal_closed: 409,
    invalid_transition: 409,
    stale_proposal: 409,
    already_voted: 409,
    decision_closed: 409,
    lease_limit_reached: 409,
    lease_expired: 409,
    evidence_required: 409,
    exceeds_hold: 409,
    idempotency_conflict: 409,
    handle_taken: 409,
    slug_taken: 409,
    account_exists: 409,
    exit_not_open: 409,
    payments_not_enabled: 409,
    agent_not_hosted: 409,
    no_compute_budget: 409,
    model_not_priced: 400,
    unsupported_feature: 400,
    provider_credentials_missing: 424,
    rate_limited: 429,
    provider_error: 502,
    gateway_timeout: 504,
    task_not_in_goal: 403,
    operator_unavailable: 403,
    funding_tier_required: 409,
    outside_money_cap_reached: 409,
    authorization_pending: 400,
    slow_down: 400,
    expired_token: 400,
    access_denied: 400,
    invalid_grant: 400,
    not_acceptable: 406,
    request_timeout: 408,
    conflict: 409,
    payload_too_large: 413,
    uri_too_long: 414,
    unsupported_media_type: 415,
    internal_error: 500,
    service_unavailable: 503
  ]

  for {code, status} <- @spec_codes do
    test "T02-T02 #{code} renders the error envelope with HTTP #{status}", %{conn: conn} do
      code = unquote(code)
      status = unquote(status)

      assert Error.status(code) == status

      error = Error.new(code, "something happened", %{"field" => "x"})
      conn = FallbackController.call(conn, {:error, error})

      assert json_response(conn, status) == %{
               "error" => %{
                 "code" => Atom.to_string(code),
                 "message" => "something happened",
                 "details" => %{"field" => "x"}
               }
             }
    end
  end

  test "T02-T02 every SPEC-07 §2 code is known to Openmaru.Error" do
    for {code, _status} <- @spec_codes do
      assert code in Error.codes(), "#{code} missing from Openmaru.Error.codes/0"
    end
  end

  test "T02-T02 a missing message defaults to a non-empty string and empty details", %{
    conn: conn
  } do
    conn = FallbackController.call(conn, {:error, Error.new(:budget_exceeded)})

    assert %{"error" => %{"code" => "budget_exceeded", "message" => message, "details" => %{}}} =
             json_response(conn, 402)

    assert is_binary(message) and message != ""
  end

  test "T02-T02 a changeset error renders validation_failed with field errors", %{conn: conn} do
    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{}, [:name])
      |> Ecto.Changeset.validate_required([:name])

    conn = FallbackController.call(conn, {:error, changeset})

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "details" => %{"fields" => %{"name" => ["can't be blank"]}}
             }
           } = json_response(conn, 422)
  end

  test "T02-T02 unknown codes map to 500 and raised errors carry their status" do
    assert Error.status(:no_such_code) == 500
    assert Plug.Exception.status(Error.new(:goal_paused)) == 423
  end
end
