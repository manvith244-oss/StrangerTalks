defmodule StrangertalksNewWeb.ParticipantIssuanceAbuseTest do
  use StrangertalksNewWeb.ConnCase, async: false

  alias StrangertalksNew.Participant
  alias StrangertalksNew.Repo

  @issuance_burst_limit 6

  test "one source cannot mint unlimited fresh participant identities" do
    source = {203, 0, 113, 10}

    Enum.each(1..@issuance_burst_limit, fn _ ->
      conn = post_from(source)
      assert %{"participant_id" => _, "token" => _} = json_response(conn, 201)
    end)

    rejected = post_from(source)

    assert %{"error" => %{"reason" => "participant_issuance_rate_limited"}} =
             json_response(rejected, 429)

    assert Repo.aggregate(Participant, :count, :participant_id) == @issuance_burst_limit
  end

  test "a different source is not charged for another source's issuance burst" do
    noisy_source = {203, 0, 113, 20}
    independent_source = {203, 0, 113, 21}

    Enum.each(1..@issuance_burst_limit, fn _ ->
      assert 201 == post_from(noisy_source).status
    end)

    assert 201 == post_from(independent_source).status
  end

  defp post_from(remote_ip) do
    build_conn()
    |> Map.put(:remote_ip, remote_ip)
    |> post(~p"/api/participants", %{})
  end
end
