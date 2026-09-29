defmodule OpenmaruWeb.FallbackController do
  @moduledoc """
  `action_fallback` target for API controllers. Turns `{:error, %Openmaru.Error{}}` into
  the error envelope with the status from `Openmaru.Error.status/1`, and
  `{:error, %Ecto.Changeset{}}` into `validation_failed` with `details.fields`.
  """

  use OpenmaruWeb, :controller

  alias Openmaru.Error
  alias OpenmaruWeb.ErrorJSON

  @doc false
  @spec call(Plug.Conn.t(), {:error, Error.t() | Ecto.Changeset.t()}) :: Plug.Conn.t()
  def call(conn, {:error, %Error{} = error}) do
    conn
    |> put_status(Error.status(error.code))
    |> json(ErrorJSON.error(error))
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    call(conn, {:error, Error.new(:validation_failed, nil, %{fields: field_errors(changeset)})})
  end

  defp field_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
