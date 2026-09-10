defmodule StrangertalksNew.SupabaseCaBundleTest do
  use ExUnit.Case, async: true

  @expected_sha256 "807025AD50D4ED219D2C9C7D299C004F824EB00CF7F65AFEF607D07B72E6CAFA"

  test "bundled Supabase root CA is present in application priv and pinned" do
    path = Application.app_dir(:strangertalks_new, "priv/certs/supabase-prod-ca-2021.crt")

    assert File.regular?(path)

    [{:Certificate, der, :not_encrypted}] =
      path
      |> File.read!()
      |> :public_key.pem_decode()

    actual_sha256 =
      :crypto.hash(:sha256, der)
      |> Base.encode16(case: :upper)

    assert actual_sha256 == @expected_sha256
  end
end
