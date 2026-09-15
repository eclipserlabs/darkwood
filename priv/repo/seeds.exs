case Darkwood.Incidents.create_sample_incident() do
  {:ok, incident} -> IO.puts("Sample incident ready: #{incident.title} (id=#{incident.id})")
  {:error, reason} -> raise "sample incident failed: #{inspect(reason)}"
end
