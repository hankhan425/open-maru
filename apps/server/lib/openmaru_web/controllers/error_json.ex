defmodule OpenmaruWeb.ErrorJSON do
  @moduledoc """
  Renders the error envelope `{"error":{"code","message","details"}}` (SPEC-07 §2).

  `error/1` renders an `Openmaru.Error`. `render/2` is called by the endpoint for
  exceptions (unknown routes, malformed bodies, crashes); it derives the code from the
  HTTP status and never includes exception messages, which may echo request content.
  """

  alias Openmaru.Error

  @doc "The envelope for an `Openmaru.Error`."
  @spec error(Error.t()) :: %{error: %{code: String.t(), message: String.t(), details: map()}}
  def error(%Error{code: code, message: message, details: details}) do
    %{error: %{code: Atom.to_string(code), message: message, details: details}}
  end

  @doc false
  def render(_template, %{reason: %Error{} = error}), do: error(error)

  def render(_template, %{reason: %Plug.Parsers.ParseError{}}) do
    error(Error.new(:invalid_request, "Malformed request body"))
  end

  def render(template, _assigns) do
    status = template |> String.split(".") |> hd() |> String.to_integer()
    message = Phoenix.Controller.status_message_from_template(template)
    error(Error.new(code_for_status(status), message))
  end

  # Each status raised outside a controller has a code that maps back to that same status
  # (SPEC-07 §2, OQ-1). A test checks every status the dependencies' exceptions carry; the
  # last two clauses only catch a status a future dependency adds.
  defp code_for_status(400), do: :invalid_request
  defp code_for_status(401), do: :unauthenticated
  defp code_for_status(403), do: :forbidden
  defp code_for_status(404), do: :not_found
  defp code_for_status(406), do: :not_acceptable
  defp code_for_status(408), do: :request_timeout
  defp code_for_status(409), do: :conflict
  defp code_for_status(413), do: :payload_too_large
  defp code_for_status(414), do: :uri_too_long
  defp code_for_status(415), do: :unsupported_media_type
  defp code_for_status(422), do: :validation_failed
  defp code_for_status(429), do: :rate_limited
  defp code_for_status(503), do: :service_unavailable
  defp code_for_status(status) when status < 500, do: :invalid_request
  defp code_for_status(_status), do: :internal_error
end
