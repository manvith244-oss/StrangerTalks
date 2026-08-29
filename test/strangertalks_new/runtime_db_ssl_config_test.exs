defmodule StrangertalksNew.RuntimeDbSslConfigTest do
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @env_vars ~w(DATABASE_URL SECRET_KEY_BASE PHX_HOST DB_CA_CERT_PATH)

  setup do
    previous_env = Map.new(@env_vars, &{&1, System.get_env(&1)})

    System.put_env("DATABASE_URL", "ecto://runtime-config-proof:proof@localhost/runtime_config")
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))
    System.put_env("PHX_HOST", "runtime-config-proof.invalid")
    System.delete_env("DB_CA_CERT_PATH")

    on_exit(fn ->
      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "unset or empty DB_CA_CERT_PATH explicitly disables Repo TLS" do
    for value <- [nil, ""] do
      set_db_ca_cert_path(value)

      repo_config = read_repo_config()

      assert Keyword.fetch!(repo_config, :ssl) == false
    end
  end

  test "relative DB_CA_CERT_PATH resolves the bundled CA through the release priv directory" do
    System.put_env("DB_CA_CERT_PATH", "priv/certs/prod-ca-2021.crt")

    repo_config = read_repo_config()
    expected_path = Application.app_dir(:strangertalks_new, "priv/certs/prod-ca-2021.crt")

    assert Keyword.fetch!(repo_config, :ssl) == [cacertfile: expected_path]
    assert File.regular?(expected_path)
  end

  defp read_repo_config do
    @runtime_config
    |> Config.Reader.read!(env: :prod, target: :host)
    |> Keyword.fetch!(:strangertalks_new)
    |> Keyword.fetch!(StrangertalksNew.Repo)
  end

  defp set_db_ca_cert_path(nil), do: System.delete_env("DB_CA_CERT_PATH")
  defp set_db_ca_cert_path(value), do: System.put_env("DB_CA_CERT_PATH", value)
end
