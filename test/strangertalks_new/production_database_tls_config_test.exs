defmodule StrangertalksNew.ProductionDatabaseTLSConfigTest do
  use ExUnit.Case, async: false

  @runtime_path Path.expand("../../config/runtime.exs", __DIR__)
  @database_url "ecto://user:password@aws-0-ap-southeast-1.pooler.supabase.com:6543/postgres"
  @database_host "aws-0-ap-southeast-1.pooler.supabase.com"
  @env_keys ~w(
    DATABASE_URL
    SECRET_KEY_BASE
    PHX_HOST
    DB_CA_CERT_FILE
    ECTO_IPV6
    POOL_SIZE
    PORT
    LOG_LEVEL
    GOOGLE_CONTINUITY_ENABLED
    PHX_SERVER
  )

  setup do
    previous_env = Map.new(@env_keys, &{&1, System.get_env(&1)})

    System.put_env("DATABASE_URL", @database_url)
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))
    System.put_env("PHX_HOST", "strangertalks.example")
    System.put_env("GOOGLE_CONTINUITY_ENABLED", "false")
    System.delete_env("DB_CA_CERT_FILE")
    System.delete_env("ECTO_IPV6")
    System.delete_env("PHX_SERVER")

    on_exit(fn ->
      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "production Repo requires verified TLS with trusted CA material and database hostname identity" do
    repo_config = production_repo_config()

    assert Keyword.fetch!(repo_config, :url) == @database_url

    ssl_options = Keyword.fetch!(repo_config, :ssl)
    assert is_list(ssl_options)
    assert Keyword.fetch!(ssl_options, :verify) == :verify_peer
    refute Keyword.get(ssl_options, :verify) == :verify_none
    assert Keyword.fetch!(ssl_options, :server_name_indication) == String.to_charlist(@database_host)

    assert trusted_ca_source?(ssl_options),
           "production TLS must carry either trusted OS CA certificates or an explicit CA file"
  end

  test "production Repo fails closed when DATABASE_URL cannot supply a hostname for certificate identity" do
    System.put_env("DATABASE_URL", "ecto:///postgres")

    assert_raise RuntimeError, ~r/database hostname.*TLS/i, fn ->
      production_repo_config()
    end
  end

  test "an explicitly configured database CA file must exist" do
    System.put_env(
      "DB_CA_CERT_FILE",
      Path.join(System.tmp_dir!(), "strangertalks-missing-db-ca-#{System.unique_integer([:positive])}.pem")
    )

    assert_raise RuntimeError, ~r/DB_CA_CERT_FILE/, fn ->
      production_repo_config()
    end
  end

  test "non-production runtime config does not force production Repo TLS settings" do
    config = Config.Reader.read!(@runtime_path, env: :test)
    app_config = Keyword.get(config, :strangertalks_new, [])

    refute Keyword.has_key?(app_config, StrangertalksNew.Repo)
  end

  defp production_repo_config do
    @runtime_path
    |> Config.Reader.read!(env: :prod)
    |> Keyword.fetch!(:strangertalks_new)
    |> Keyword.fetch!(StrangertalksNew.Repo)
  end

  defp trusted_ca_source?(ssl_options) do
    case {Keyword.get(ssl_options, :cacerts), Keyword.get(ssl_options, :cacertfile)} do
      {certs, nil} when is_list(certs) and certs != [] -> true
      {nil, path} when is_binary(path) and path != "" -> true
      _ -> false
    end
  end
end
