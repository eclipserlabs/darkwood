defmodule Darkwood.Incidents do
  import Ecto.Query
  alias Ecto.Multi
  alias Darkwood.Repo
  alias Darkwood.Incidents.{Annotation, Incident, IncidentEvent}

  @sample_title "Checkout API 500 spike"

  def list_incidents, do: Repo.all(from i in Incident, order_by: [desc: i.inserted_at])
  def get_incident!(id), do: Repo.get!(Incident, id)

  def get_incident_with_events!(id) do
    Incident
    |> Repo.get!(id)
    |> Repo.preload(events: from(e in IncidentEvent, order_by: [asc: e.occurred_at]))
  end

  def change_incident(incident \\ %Incident{}, attrs \\ %{}) do
    Incident.changeset(incident, attrs)
  end

  def create_incident(attrs), do: %Incident{} |> Incident.changeset(attrs) |> Repo.insert()

  def list_events(%Incident{id: id}), do: list_events(id)

  def list_events(id) do
    Repo.all(from e in IncidentEvent, where: e.incident_id == ^id, order_by: [asc: e.occurred_at])
  end

  def list_annotations(%Incident{id: id}), do: list_annotations(id)

  def list_annotations(id) do
    Repo.all(
      from a in Annotation,
        where: a.incident_id == ^id,
        order_by: [asc: a.inserted_at],
        preload: [:event]
    )
  end

  def change_annotation(attrs \\ %{}), do: Annotation.changeset(%Annotation{}, attrs)

  def create_annotation(%Incident{} = incident, attrs) do
    event_id = attrs["event_id"] || attrs[:event_id]

    with :ok <- event_belongs_to_incident(event_id, incident.id),
         {:ok, annotation} <-
           %Annotation{
             incident_id: incident.id,
             author_name: attrs["author_name"] || attrs[:author_name]
           }
           |> Annotation.changeset(attrs)
           |> Repo.insert() do
      broadcast(incident.id, {:annotation_created, annotation})
      {:ok, annotation}
    end
  end

  def update_incident_status(%Incident{} = incident, status) do
    case incident |> Incident.status_changeset(%{status: status}) |> Repo.update() do
      {:ok, updated} ->
        broadcast(updated.id, {:incident_updated, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  def topic(id), do: "incident:#{id}"
  def subscribe(id), do: Phoenix.PubSub.subscribe(Darkwood.PubSub, topic(id))

  def create_sample_incident do
    case Repo.get_by(Incident, title: @sample_title) do
      %Incident{} = incident -> {:ok, incident}
      nil -> insert_sample()
    end
  end

  defp insert_sample do
    base = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:microsecond)

    incident =
      Incident.changeset(%Incident{}, %{
        title: @sample_title,
        summary:
          "Elevated checkout failures traced across request, database, and payment upstream boundaries.",
        severity: :critical
      })

    events = [
      %{
        occurred_at: base,
        kind: :request,
        level: :info,
        message: "Checkout request volume crossed alert threshold",
        metadata: %{route: "/api/checkout", rate_per_minute: 184}
      },
      %{
        occurred_at: DateTime.add(base, 45),
        kind: :query,
        level: :warning,
        message: "Inventory reservation query latency increased",
        metadata: %{duration_ms: 842, operation: "reserve_inventory"}
      },
      %{
        occurred_at: DateTime.add(base, 83),
        kind: :query,
        level: :warning,
        message: "Connection pool wait exceeded budget",
        metadata: %{wait_ms: 510, pool: "primary"}
      },
      %{
        occurred_at: DateTime.add(base, 121),
        kind: :http,
        level: :error,
        message: "Payment provider returned upstream 503",
        metadata: %{status: 503, service: "payment-gateway"}
      },
      %{
        occurred_at: DateTime.add(base, 128),
        kind: :error,
        level: :error,
        message: "Checkout API response failed with status 500",
        fingerprint: "checkout-500-upstream",
        metadata: %{route: "/api/checkout", status: 500}
      }
    ]

    Multi.new()
    |> Multi.insert(:incident, incident)
    |> Multi.run(:events, fn repo, %{incident: created} ->
      Enum.reduce_while(events, {:ok, []}, fn attrs, {:ok, acc} ->
        result =
          %IncidentEvent{incident_id: created.id}
          |> IncidentEvent.changeset(attrs)
          |> repo.insert()

        case result do
          {:ok, event} -> {:cont, {:ok, [event | acc]}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{incident: incident}} ->
        {:ok, incident}

      {:error, :incident, _changeset, _changes} ->
        {:ok, Repo.get_by!(Incident, title: @sample_title)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp event_belongs_to_incident(nil, _incident_id), do: :ok
  defp event_belongs_to_incident("", _incident_id), do: :ok

  defp event_belongs_to_incident(event_id, incident_id) when is_binary(event_id) do
    case Integer.parse(event_id) do
      {parsed, ""} -> event_belongs_to_incident(parsed, incident_id)
      _ -> {:error, :event_not_in_incident}
    end
  end

  defp event_belongs_to_incident(event_id, incident_id) when is_integer(event_id) do
    if Repo.exists?(
         from e in IncidentEvent, where: e.id == ^event_id and e.incident_id == ^incident_id
       ) do
      :ok
    else
      {:error, :event_not_in_incident}
    end
  end

  defp event_belongs_to_incident(_event_id, _incident_id), do: {:error, :event_not_in_incident}

  defp broadcast(id, message), do: Phoenix.PubSub.broadcast(Darkwood.PubSub, topic(id), message)
end
