defmodule DarkwoodWeb.Presence do
  use Phoenix.Presence, otp_app: :darkwood, pubsub_server: Darkwood.PubSub
end
