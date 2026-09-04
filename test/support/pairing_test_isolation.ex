defmodule StrangertalksNew.PairingTestIsolation do
  @moduledoc false

  alias Ecto.Adapters.SQL.Sandbox
  alias StrangertalksNew.Repo

  @tables [
    {"participants", "participant_id"},
    {"matches", "match_id"},
    {"conversations", "conversation_id"}
  ]

  def install! do
    baseline = Sandbox.unboxed_run(Repo, &snapshot/0)

    ExUnit.Callbacks.on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> cleanup!(baseline) end)
    end)

    :ok
  end

  defp snapshot do
    Map.new(@tables, fn {table, id_column} ->
      {table, ids!(table, id_column)}
    end)
  end

  defp cleanup!(baseline) do
    delete_new!("participant_pairing_reservations", "match_id", baseline["matches"])
    delete_new!("conversations", "conversation_id", baseline["conversations"])
    delete_new!("matches", "match_id", baseline["matches"])
    delete_new!("participants", "participant_id", baseline["participants"])
  end

  defp ids!(table, id_column) do
    %{rows: rows} = Repo.query!("SELECT #{id_column}::text FROM #{table}")
    Enum.map(rows, &hd/1)
  end

  defp delete_new!(table, id_column, baseline_ids) do
    Repo.query!(
      "DELETE FROM #{table} WHERE NOT (#{id_column}::text = ANY($1::text[]))",
      [baseline_ids]
    )
  end
end
