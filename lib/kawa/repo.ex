defmodule Kawa.Repo do
  use Ecto.Repo,
    otp_app: :kawa,
    adapter: Ecto.Adapters.Postgres
end
