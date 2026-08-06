defmodule StrangertalksNew.GoogleProviderDriveTest do
  use ExUnit.Case, async: true

  alias StrangertalksNew.GoogleContinuity.GoogleProvider

  @limit 10 * 1024 * 1024

  test "Content-Length above the encrypted envelope limit is rejected before buffering" do
    assert {:error, :sync_payload_too_large} = GoogleProvider.bounded_body(["small"], @limit + 1)
  end

  test "chunked response aborts as soon as actual bytes cross the limit" do
    assert {:error, :sync_payload_too_large} =
             GoogleProvider.bounded_body([:binary.copy("a", @limit), "b"])
  end

  test "exactly-at-limit encrypted response is accepted" do
    body = :binary.copy("a", @limit)
    assert {:ok, ^body} = GoogleProvider.bounded_body([body], @limit)
  end

  test "cached and search-discovered downloads share the same hard bound" do
    assert {:error, :sync_payload_too_large} =
             GoogleProvider.bounded_body([:binary.copy("a", @limit + 1)])
  end

  test "bounded response collector preserves chunk order" do
    assert {:ok, "canonical"} = GoogleProvider.bounded_body(["can", "on", "ical"])
  end
end
