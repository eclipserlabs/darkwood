defmodule Darkwood.Repo do
  use Ecto.Repo,
    otp_app: :darkwood,
    adapter: Ecto.Adapters.Postgres
end
