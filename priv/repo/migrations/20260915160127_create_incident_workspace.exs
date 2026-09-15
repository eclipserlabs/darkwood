defmodule Darkwood.Repo.Migrations.CreateIncidentWorkspace do
  use Ecto.Migration

  def change do
    create table(:incidents) do
      add :title, :string, null: false
      add :summary, :text
      add :severity, :string, null: false, default: "minor"
      add :status, :string, null: false, default: "investigating"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:incidents, [:status])
    create index(:incidents, [:severity])
    create index(:incidents, [:inserted_at])

    create unique_index(:incidents, [:title],
             where: "title = 'Checkout API 500 spike'",
             name: :incidents_sample_title_index
           )

    create table(:incident_events) do
      add :incident_id, references(:incidents, on_delete: :delete_all), null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :kind, :string, null: false
      add :level, :string, null: false
      add :message, :text, null: false
      add :fingerprint, :string
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:incident_events, [:incident_id])
    create index(:incident_events, [:occurred_at])
    create index(:incident_events, [:incident_id, :occurred_at])

    create table(:annotations) do
      add :incident_id, references(:incidents, on_delete: :delete_all), null: false
      add :event_id, references(:incident_events, on_delete: :delete_all)
      add :author_name, :string, null: false
      add :body, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:annotations, [:incident_id])
    create index(:annotations, [:event_id])
    create index(:annotations, [:incident_id, :inserted_at])
  end
end
