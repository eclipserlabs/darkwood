defmodule Darkwood.Repo.Migrations.AddIncidentEventsFingerprintIndex do
  use Ecto.Migration

  def change do
    create index(:incident_events, [:incident_id, :fingerprint])
  end
end
