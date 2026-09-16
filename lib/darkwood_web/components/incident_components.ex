defmodule DarkwoodWeb.IncidentComponents do
  @moduledoc """
  Presentation helpers for incident events, including aggregated ingestion state.
  """
  use DarkwoodWeb, :html

  attr :event, :any, required: true

  def aggregation_badge(assigns) do
    count = aggregation_count(assigns.event)
    range = aggregation_range(assigns.event)
    assigns = assign(assigns, :count, count) |> assign(:range, range)

    ~H"""
    <span
      :if={@count > 1}
      id={"aggregation-badge-#{@event.id}"}
      class="inline-flex items-center gap-2 rounded-full border border-amber-700 bg-amber-950 px-3 py-1 text-xs font-semibold text-amber-300"
    >
      [{@count}x]
      <span :if={@range} class="font-normal text-amber-400/80">{@range}</span>
    </span>
    """
  end

  @doc "Effective occurrence count from aggregation metadata (defaults to 1)."
  def aggregation_count(%{metadata: metadata}) when is_map(metadata) do
    metadata["count"] || metadata[:count] || 1
  end

  def aggregation_count(_), do: 1

  @doc "Human-readable first_seen → last_seen range, or nil."
  def aggregation_range(%{metadata: metadata}) when is_map(metadata) do
    first = metadata["first_seen"] || metadata[:first_seen]
    last = metadata["last_seen"] || metadata[:last_seen]

    case {first, last} do
      {nil, _} -> nil
      {_, nil} -> nil
      {f, l} when f == l -> to_string(f)
      {f, l} -> "#{f} → #{l}"
    end
  end

  def aggregation_range(_), do: nil
end
