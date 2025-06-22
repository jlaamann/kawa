ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Kawa.Repo, :manual)
Logger.configure(level: :info)

# Configure test compensation client for all tests
Application.put_env(:kawa, :compensation_client, Kawa.Execution.CompensationClient.Test)
