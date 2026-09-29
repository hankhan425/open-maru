defmodule OpenmaruWeb.Plugs.Idempotency do
  @moduledoc """
  Honours the `Idempotency-Key` header on mutations (CONVENTIONS §5).

  For `POST`, `PUT`, `PATCH` and `DELETE` requests carrying the header, the key is
  scoped to the principal (`conn.assigns.current_actor`, or `anonymous:<ip>`) and bound
  to a fingerprint of method, path, query and body params:

    * first use — the request runs and its response is stored for 24 hours;
    * same key, same request — the stored status and body are replayed with
      `idempotent-replayed: true`, without running the action;
    * same key, different request (or the first still running) — 409
      `idempotency_conflict`.

  5xx and streamed responses are not stored. Requests without the header pass through.
  """

  @behaviour Plug

  import Plug.Conn

  alias Openmaru.{Error, Idempotency}
  alias Openmaru.Idempotency.Key
  alias OpenmaruWeb.FallbackController

  @header "idempotency-key"
  @max_key_length 255
  @mutations ~w(POST PUT PATCH DELETE)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in @mutations do
    case get_req_header(conn, @header) do
      [] -> conn
      [key | _] -> handle(conn, key)
    end
  end

  def call(conn, _opts), do: conn

  defp handle(conn, key) when byte_size(key) == 0 or byte_size(key) > @max_key_length do
    error = Error.new(:invalid_request, "Idempotency-Key must be 1-#{@max_key_length} bytes")
    conn |> FallbackController.call({:error, error}) |> halt()
  end

  defp handle(conn, key) do
    case Idempotency.claim(principal(conn), key, request_hash(conn)) do
      {:execute, record} ->
        register_before_send(conn, &store(&1, record))

      {:replay, %Key{status: status, body: body}} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("idempotent-replayed", "true")
        |> send_resp(status, body)
        |> halt()

      {:error, %Error{} = error} ->
        conn |> FallbackController.call({:error, error}) |> halt()
    end
  end

  defp store(%Plug.Conn{state: :set, status: status, resp_body: body} = conn, record)
       when not is_nil(body) do
    :ok = Idempotency.complete(record, status, IO.iodata_to_binary(body))
    conn
  end

  defp store(conn, record) do
    :ok = Idempotency.release(record)
    conn
  end

  defp principal(conn) do
    case conn.assigns[:current_actor] do
      {kind, %{id: id}} -> "#{kind}:#{id}"
      {kind, %{id: id}, _claims} -> "#{kind}:#{id}"
      _ -> "anonymous:" <> (conn.remote_ip |> :inet.ntoa() |> to_string())
    end
  end

  defp request_hash(conn) do
    fingerprint = {conn.method, conn.path_info, conn.query_params, conn.body_params}

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(fingerprint, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
