defmodule StrangertalksNew.GoogleContinuityConfigTest do
  use ExUnit.Case, async: false

  alias StrangertalksNew.GoogleContinuity

  setup do
    previous = Application.get_env(:strangertalks_new, :google_continuity)
    on_exit(fn -> Application.put_env(:strangertalks_new, :google_continuity, previous) end)
  end

  test "enabled configuration requires exactly 32 decoded HMAC bytes" do
    base = [
      enabled: true,
      client_id: "id",
      client_secret: "secret",
      redirect_uri: "uri",
      refresh_token_encryption_key: Base.encode64(:binary.copy(<<1>>, 32))
    ]

    Application.put_env(
      :strangertalks_new,
      :google_continuity,
      Keyword.put(base, :subject_hmac_key, Base.encode64(:binary.copy(<<2>>, 32)))
    )

    assert GoogleContinuity.required_config!()[:enabled]

    for invalid <- [
          nil,
          "%%%",
          Base.encode64(:binary.copy(<<2>>, 31)),
          Base.encode64(:binary.copy(<<2>>, 33))
        ] do
      Application.put_env(
        :strangertalks_new,
        :google_continuity,
        Keyword.put(base, :subject_hmac_key, invalid)
      )

      assert_raise RuntimeError, fn -> GoogleContinuity.required_config!() end
    end
  end

  test "disabled guest configuration needs no Google keys" do
    Application.put_env(:strangertalks_new, :google_continuity, enabled: false)
    assert GoogleContinuity.required_config!() == [enabled: false]
  end
end
