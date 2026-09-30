defmodule Openmaru.RuntimeConfigTest do
  # Reads config/runtime.exs as production does, with environment variables set here.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  @base %{
    "DATABASE_URL" => "ecto://user:pass@localhost/openmaru",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PHX_HOST" => "app.openmaru.org",
    "WEB_URL" => "https://app.openmaru.org",
    "WEBAUTHN_RP_ID" => "openmaru.org",
    "AUDIT_IP_HASH_KEY" => String.duplicate("k", 32),
    "AUTH_RATE_LIMIT_PER_MINUTE" => nil,
    "TRUSTED_PROXIES" => nil
  }

  # Runs runtime.exs for :prod with `@base` merged with `overrides` (nil unsets), then
  # restores the environment.
  defp prod_config(overrides) do
    vars = Map.merge(@base, overrides)
    saved = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)

    try do
      Enum.each(vars, &put_env/1)
      Config.Reader.read!(@runtime, env: :prod)
    after
      Enum.each(saved, &put_env/1)
    end
  end

  defp put_env({name, nil}), do: System.delete_env(name)
  defp put_env({name, value}), do: System.put_env(name, value)

  test "C01-T01 production takes the WebAuthn rp id from WEBAUTHN_RP_ID" do
    webauthn = prod_config(%{})[:openmaru][Openmaru.Accounts.WebAuthn]

    assert webauthn[:rp_id] == "openmaru.org"
    assert webauthn[:origin] == "https://app.openmaru.org"
  end

  test "C01-T01 production refuses to start without WEBAUTHN_RP_ID" do
    assert_raise RuntimeError, ~r/WEBAUTHN_RP_ID is missing/, fn ->
      prod_config(%{"WEBAUTHN_RP_ID" => nil})
    end
  end

  test "C01-T01 the rp id must be the web host or a parent domain of it" do
    assert prod_config(%{"WEBAUTHN_RP_ID" => "app.openmaru.org"})[:openmaru][
             Openmaru.Accounts.WebAuthn
           ][:rp_id] == "app.openmaru.org"

    for rp_id <- ["other.org", "penmaru.org", "x.app.openmaru.org"] do
      assert_raise RuntimeError, ~r/must be WEB_URL's host/, fn ->
        prod_config(%{"WEBAUTHN_RP_ID" => rp_id})
      end
    end
  end

  test "C01-T18 production hashes audit IPs with AUDIT_IP_HASH_KEY, not SECRET_KEY_BASE" do
    config = prod_config(%{})

    assert config[:openmaru][Openmaru.Audit][:ip_hash_key] == String.duplicate("k", 32)

    assert_raise RuntimeError, ~r/AUDIT_IP_HASH_KEY is missing/, fn ->
      prod_config(%{"AUDIT_IP_HASH_KEY" => nil})
    end

    assert_raise RuntimeError, ~r/at least 32 bytes/, fn ->
      prod_config(%{"AUDIT_IP_HASH_KEY" => "short"})
    end
  end

  test "C01-T17 the auth limit and trusted proxies come from the environment" do
    config = prod_config(%{})
    assert config[:openmaru][OpenmaruWeb.Plugs.RateLimit][:limits][:auth][:limit] == 10
    assert config[:openmaru][OpenmaruWeb.Plugs.ClientIP][:trusted_proxies] == []

    config =
      prod_config(%{
        "AUTH_RATE_LIMIT_PER_MINUTE" => "100",
        "TRUSTED_PROXIES" => "10.0.0.0/8,fd00::/8"
      })

    assert config[:openmaru][OpenmaruWeb.Plugs.RateLimit][:limits][:auth] ==
             [limit: 100, scale_ms: 60_000]

    assert config[:openmaru][OpenmaruWeb.Plugs.ClientIP][:trusted_proxies] ==
             ["10.0.0.0/8", "fd00::/8"]
  end
end
