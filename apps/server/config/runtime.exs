import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/openmaru start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :openmaru, OpenmaruWeb.Endpoint, server: true
end

config :openmaru, OpenmaruWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# OAuth credentials (C01). A provider without a client id stays disabled.
if config_env() != :test do
  oauth_provider = fn prefix ->
    [
      client_id: System.get_env(prefix <> "_CLIENT_ID"),
      client_secret: System.get_env(prefix <> "_CLIENT_SECRET")
    ]
  end

  config :openmaru, Openmaru.Accounts.OAuth,
    providers: [github: oauth_provider.("GITHUB"), google: oauth_provider.("GOOGLE")]

  # SPEC-09 §6 sets 10; raise it where many sign-ins share one IP (e2e runs, demos).
  config :openmaru, OpenmaruWeb.Plugs.RateLimit,
    limits: [
      auth: [
        limit: String.to_integer(System.get_env("AUTH_RATE_LIMIT_PER_MINUTE", "10")),
        scale_ms: 60_000
      ]
    ]

  # Load balancers in front of the app (comma-separated CIDRs). Unset: x-forwarded-for
  # is ignored and the TCP peer is the client.
  config :openmaru, OpenmaruWeb.Plugs.ClientIP,
    trusted_proxies: "TRUSTED_PROXIES" |> System.get_env("") |> String.split(",", trim: true)
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :openmaru, Openmaru.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :openmaru, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # C01: the SPA is served from the same host in production.
  web_url = System.get_env("WEB_URL") || "https://#{host}"
  config :openmaru, :web_url, web_url

  # Every passkey is bound to the relying party id, so it can never change: set it
  # explicitly (the registrable domain, e.g. openmaru.org) instead of deriving it.
  rp_id =
    System.get_env("WEBAUTHN_RP_ID") ||
      raise """
      environment variable WEBAUTHN_RP_ID is missing.
      It is the WebAuthn relying party id, e.g. openmaru.org. Passkeys are bound to it
      for good, so pick the registrable domain rather than a subdomain.
      """

  web_host = URI.parse(web_url).host

  unless web_host == rp_id or String.ends_with?(web_host, "." <> rp_id) do
    raise "WEBAUTHN_RP_ID (#{rp_id}) must be WEB_URL's host (#{web_host}) or a parent domain"
  end

  config :openmaru, Openmaru.Accounts.WebAuthn,
    rp_id: rp_id,
    rp_name: "openmaru",
    origin: web_url

  # A key of its own, so rotating SECRET_KEY_BASE leaves audit IP hashes comparable.
  audit_ip_hash_key =
    System.get_env("AUDIT_IP_HASH_KEY") ||
      raise """
      environment variable AUDIT_IP_HASH_KEY is missing.
      It keys the audit log's IP hashes (SPEC-09 §7). Generate one with: mix phx.gen.secret
      """

  if byte_size(audit_ip_hash_key) < 32 do
    raise "AUDIT_IP_HASH_KEY must be at least 32 bytes"
  end

  config :openmaru, Openmaru.Audit, ip_hash_key: audit_ip_hash_key

  config :openmaru, OpenmaruWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :openmaru, OpenmaruWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :openmaru, OpenmaruWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
