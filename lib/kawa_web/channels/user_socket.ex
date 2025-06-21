defmodule KawaWeb.UserSocket do
  use Phoenix.Socket

  # Channels for client connections
  channel "client:*", KawaWeb.ClientChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    # Allow connection - authentication happens in channel join
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
