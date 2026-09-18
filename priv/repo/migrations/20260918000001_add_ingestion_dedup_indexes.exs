defmodule Darkwood.Repo.Migrations.AddIngestionDedupIndexes do
  use Ecto.Migration

  def change do
    create_if_not_exists index(:incident_events, [:incident_id, :fingerprint, :inserted_at])
    create_if_not_exists index(:annotations, [:incident_id, :inserted_at])
  end
end
