defmodule DarkwoodWeb.IncidentIndexLive do
  use DarkwoodWeb, :live_view
  alias Darkwood.Incidents

  @impl true
  def mount(_params, _session, socket) do
    incidents = Incidents.list_incidents()

    if connected?(socket), do: :ok = Incidents.subscribe_incidents()

    {:ok,
     socket
     |> assign(:page_title, "Incidents")
     |> assign(:empty?, incidents == [])
     |> assign(:form, to_form(Incidents.change_incident()))
     |> stream(:incidents, incidents)}
  end

  @impl true
  def handle_info({:incident_created, incident}, socket) do
    {:noreply, socket |> stream_insert(:incidents, incident, at: 0) |> assign(:empty?, false)}
  end

  @impl true
  def handle_event("validate", %{"incident" => params}, socket) do
    form =
      Incidents.change_incident(%Darkwood.Incidents.Incident{}, params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"incident" => params}, socket) do
    case Incidents.create_incident(params) do
      {:ok, incident} ->
        {:noreply, push_navigate(socket, to: ~p"/incidents/#{incident}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def handle_event("create_sample", _params, socket) do
    case Incidents.create_sample_incident() do
      {:ok, incident} ->
        {:noreply, push_navigate(socket, to: ~p"/incidents/#{incident}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create the sample incident.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-10">
        <header class="flex items-end justify-between gap-6 border-b border-slate-800 pb-6">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.3em] text-amber-400">
              Incident command
            </p><h1 class="mt-2 text-4xl font-semibold text-white">Darkwood</h1><p class="mt-2 text-slate-400">
              Signed in as {@display_name}
            </p>
          </div>
          <div class="flex items-center gap-3">
            <span class="rounded-full border border-emerald-800 bg-emerald-950 px-3 py-1 text-xs font-medium text-emerald-300">Operational</span>
            <.link
              id="logout"
              href={~p"/logout"}
              method="delete"
              class="rounded-lg border border-slate-700 px-3 py-1 text-xs text-slate-300 hover:border-slate-500 hover:text-white"
            >Sign out</.link>
          </div>
        </header>

        <section id="incident-list" phx-update="stream" class="grid gap-3">
          <div
            id="incident-empty"
            class="hidden only:block rounded-xl border border-dashed border-slate-700 bg-slate-950 p-8 text-center"
          >
            <p class="text-slate-300">No incidents are open yet.</p>
            <button
              id="create-sample"
              phx-click="create_sample"
              class="mt-4 rounded-lg bg-amber-400 px-4 py-2 font-semibold text-slate-950"
            >Create sample incident</button>
          </div>
          <.link
            :for={{id, incident} <- @streams.incidents}
            id={id}
            navigate={~p"/incidents/#{incident}"}
            class="group grid grid-cols-[auto_1fr_auto] items-center gap-4 rounded-xl border border-slate-800 bg-slate-950 p-5 transition hover:border-slate-600"
          >
            <span class={["h-10 w-1 rounded-full", severity_color(incident.severity)]}></span>
            <div>
              <h2 class="font-semibold text-white group-hover:text-amber-300">{incident.title}</h2><p class="mt-1 text-xs uppercase tracking-wider text-slate-500">
                {incident.severity} · {incident.status}
              </p>
            </div>
            <time class="text-sm text-slate-500">{Calendar.strftime(
              incident.inserted_at,
              "%b %d, %H:%M UTC"
            )}</time>
          </.link>
        </section>

        <section class="rounded-xl border border-slate-800 bg-slate-950 p-6">
          <h2 class="text-lg font-semibold text-white">Open an incident</h2>
          <.form
            for={@form}
            id="incident-form"
            phx-change="validate"
            phx-submit="save"
            class="mt-5 grid gap-4 sm:grid-cols-2"
          >
            <div class="sm:col-span-2">
              <.input field={@form[:title]} label="Title" minlength="3" maxlength="120" />
            </div>
            <.input
              field={@form[:severity]}
              type="select"
              label="Severity"
              options={[Minor: :minor, Major: :major, Critical: :critical]}
            />
            <div class="sm:col-span-2">
              <.input
                field={@form[:summary]}
                type="textarea"
                label="Summary (optional)"
                maxlength="2000"
              />
            </div>
            <button
              id="incident-submit"
              class="w-fit rounded-lg bg-amber-400 px-5 py-2.5 font-semibold text-slate-950 transition hover:bg-amber-300"
            >Create incident</button>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp severity_color(:critical), do: "bg-red-500"
  defp severity_color(:major), do: "bg-orange-400"
  defp severity_color(_), do: "bg-sky-400"
end
