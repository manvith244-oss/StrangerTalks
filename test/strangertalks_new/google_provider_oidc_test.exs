defmodule StrangertalksNew.GoogleProviderOIDCTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.GoogleContinuity.GoogleProvider

  @now 1_800_000_000
  @audience "client-id"
  @nonce "expected-nonce"

  setup do
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_kind, public} = JOSE.JWK.to_public_map(key)
    {:ok, key: key, keys: [Map.put(public, "kid", "primary")]}
  end

  test "valid signed token succeeds", context do
    assert {:ok, _} = verify(context, %{})
  end

  test "nonce mismatch is rejected", context do
    assert_invalid(context, %{"nonce" => "wrong"})
  end

  test "invalid issuer is rejected", context do
    assert_invalid(context, %{"iss" => "https://attacker.invalid"})
  end

  test "invalid audience is rejected", context do
    assert_invalid(context, %{"aud" => "other"})
  end

  test "expired token is rejected", context do
    assert_invalid(context, %{"exp" => @now - 61})
  end

  test "unreasonably future iat is rejected", context do
    assert_invalid(context, %{"iat" => @now + 61})
  end

  test "invalid signature is rejected", context do
    other = JOSE.JWK.generate_key({:rsa, 2048})
    token = signed(other, claims(%{}), "primary")

    assert {:error, :invalid_id_token} =
             GoogleProvider.verify_id_token_with_keys(
               token,
               @audience,
               @nonce,
               context.keys,
               @now
             )
  end

  test "alg none is rejected", context do
    token =
      [Jason.encode!(%{alg: "none", kid: "primary"}), Jason.encode!(claims(%{})), ""]
      |> Enum.map(&Base.url_encode64(&1, padding: false))
      |> Enum.join(".")

    assert {:error, :invalid_id_token} =
             GoogleProvider.verify_id_token_with_keys(
               token,
               @audience,
               @nonce,
               context.keys,
               @now
             )
  end

  test "alternate algorithm is rejected", context do
    secret = JOSE.JWK.from_oct("not-an-rsa-key-but-long-enough")

    token =
      JOSE.JWT.sign(secret, %{"alg" => "HS256", "kid" => "primary"}, claims(%{}))
      |> JOSE.JWS.compact()
      |> elem(1)

    assert {:error, :invalid_id_token} =
             GoogleProvider.verify_id_token_with_keys(
               token,
               @audience,
               @nonce,
               context.keys,
               @now
             )
  end

  test "unknown kid is rejected", context do
    token = signed(context.key, claims(%{}), "unknown")

    assert {:error, :invalid_id_token} =
             GoogleProvider.verify_id_token_with_keys(
               token,
               @audience,
               @nonce,
               context.keys,
               @now
             )
  end

  test "multiple audiences require matching azp", context do
    assert_invalid(context, %{"aud" => [@audience, "other"], "azp" => "other"})
  end

  test "missing or malformed sub is rejected", context do
    assert_invalid(context, %{"sub" => ""})
  end

  defp verify(context, overrides) do
    token = signed(context.key, claims(overrides), "primary")
    GoogleProvider.verify_id_token_with_keys(token, @audience, @nonce, context.keys, @now)
  end

  defp assert_invalid(context, overrides),
    do: assert({:error, :invalid_id_token} = verify(context, overrides))

  defp claims(overrides) do
    Map.merge(
      %{
        "iss" => "https://accounts.google.com",
        "aud" => @audience,
        "exp" => @now + 300,
        "iat" => @now,
        "nonce" => @nonce,
        "sub" => "private-subject"
      },
      overrides
    )
  end

  defp signed(key, claims, kid),
    do:
      JOSE.JWT.sign(key, %{"alg" => "RS256", "kid" => kid}, claims)
      |> JOSE.JWS.compact()
      |> elem(1)
end
