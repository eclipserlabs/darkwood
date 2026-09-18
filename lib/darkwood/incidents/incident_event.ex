defmodule Darkwood.Incidents.IncidentEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "incident_events" do
    field :occurred_at, :utc_datetime_usec
    field :kind, Ecto.Enum, values: [:request, :query, :http, :log, :error]
    field :level, Ecto.Enum, values: [:info, :warning, :error]
    field :message, :string
    field :fingerprint, :string
    field :metadata, :map, default: %{}
    belongs_to :incident, Darkwood.Incidents.Incident
    has_many :annotations, Darkwood.Incidents.Annotation, foreign_key: :event_id
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:occurred_at, :kind, :level, :message, :fingerprint, :metadata])
    |> validate_required([:occurred_at, :kind, :level, :message])
    |> validate_length(:message, min: 1, max: 5000)
    |> validate_length(:fingerprint, max: 128)
    |> foreign_key_constraint(:incident_id)
  end
end
