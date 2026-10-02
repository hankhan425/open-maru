defmodule OpenmaruWeb.SocketToken do
  @moduledoc """
  Short-lived tokens for Phoenix Channels (SPEC-07 §3). A web client signed in with the
  session cookie fetches one from `GET /api/v1/socket-token` and passes it when it
  connects the socket (C05); the CLI uses its PAT instead.

  The token is signed (`Phoenix.Token`, endpoint secret, its own salt) and carries the
  user id and an expiry 5 minutes after signing, both by `Openmaru.Clock`.
  `verify_socket_token/1` refuses anything expired, tampered with, or signed for
  another purpose with `{:error, :invalid}`. It does not read the database: the socket
  loads the user and refuses a suspended one, as for any credential.
  """

  alias Openmaru.Accounts.User
  alias Openmaru.Clock

  @salt "openmaru socket v1"
  @ttl_seconds 300

  @doc "Seconds a socket token is valid."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc "A socket token for `user`, valid for #{@ttl_seconds} seconds."
  @spec sign_socket_token(User.t()) :: String.t()
  def sign_socket_token(%User{id: user_id}) do
    expires_at = Clock.now() |> DateTime.add(@ttl_seconds, :second) |> to_us()

    # Expiry is checked against Openmaru.Clock, not by Phoenix.Token's wall clock.
    Phoenix.Token.sign(
      OpenmaruWeb.Endpoint,
      @salt,
      %{"user_id" => user_id, "exp" => expires_at},
      max_age: :infinity
    )
  end

  @doc "The user id a valid, unexpired socket token was signed for."
  @spec verify_socket_token(term()) :: {:ok, Ecto.UUID.t()} | {:error, :invalid}
  def verify_socket_token(token) when is_binary(token) do
    case Phoenix.Token.verify(OpenmaruWeb.Endpoint, @salt, token, max_age: :infinity) do
      {:ok, %{"user_id" => user_id, "exp" => expires_at}} when is_integer(expires_at) ->
        if to_us(Clock.now()) < expires_at, do: {:ok, user_id}, else: {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  end

  def verify_socket_token(_token), do: {:error, :invalid}

  defp to_us(datetime), do: DateTime.to_unix(datetime, :microsecond)
end
