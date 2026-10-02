defmodule Openmaru.Error do
  @moduledoc """
  The error value returned by domain functions (CONVENTIONS §4):
  `{:error, %Openmaru.Error{code: atom, message: String.t(), details: map}}`.

  `code` is a stable snake_case atom from SPEC-07 §2; `status/1` maps it to the HTTP
  status used by `OpenmaruWeb.FallbackController`. Tests assert on codes, not messages.
  Messages must never contain secrets, tokens, or request contents.
  """

  defexception [:code, :message, details: %{}]

  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}

  # SPEC-07 §2. The last group names the HTTP statuses raised outside controllers
  # (transport errors, unhandled exceptions), so every status has its own code (OQ-1).
  @statuses %{
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
    task_not_in_goal: 403,
    budget_exceeded: 402,
    goal_funds_insufficient: 402,
    goal_paused: 423,
    not_found: 404,
    invalid_request: 400,
    model_not_priced: 400,
    unsupported_feature: 400,
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
    must_be_removed_by_amendment: 409,
    account_exists: 409,
    payments_not_enabled: 409,
    agent_not_hosted: 409,
    no_compute_budget: 409,
    provider_credentials_missing: 424,
    rate_limited: 429,
    provider_error: 502,
    gateway_timeout: 504,
    # Device login (RFC 8628 §3.5, which answers them all with 400).
    authorization_pending: 400,
    slow_down: 400,
    expired_token: 400,
    access_denied: 400,
    invalid_grant: 400,
    # Raised before or outside a controller (`OpenmaruWeb.ErrorJSON`).
    not_acceptable: 406,
    request_timeout: 408,
    conflict: 409,
    payload_too_large: 413,
    uri_too_long: 414,
    unsupported_media_type: 415,
    internal_error: 500,
    service_unavailable: 503
  }

  @doc """
  Builds an error. A `nil` message defaults to a humanized form of the code
  (`:budget_exceeded` → `"Budget exceeded"`).
  """
  @spec new(atom(), String.t() | nil, map()) :: t()
  def new(code, message \\ nil, details \\ %{}) when is_atom(code) and is_map(details) do
    %__MODULE__{code: code, message: message || default_message(code), details: details}
  end

  @doc "HTTP status for `code` (SPEC-07 §2); unknown codes map to 500."
  @spec status(atom()) :: 400..599
  def status(code) when is_atom(code), do: Map.get(@statuses, code, 500)

  @doc "All known error codes."
  @spec codes() :: [atom()]
  def codes, do: Map.keys(@statuses)

  defp default_message(code) do
    code |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defimpl Plug.Exception do
    def status(%{code: code}), do: Openmaru.Error.status(code)
    def actions(_error), do: []
  end
end
