defmodule KawaWeb.SagaLive.Index do
  use KawaWeb, :live_view

  require Logger

  alias Kawa.Contexts.Sagas

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:sagas, [])
      |> assign(:meta, %{})
      |> assign(:loading, true)
      |> assign(:selected_saga, nil)
      |> assign(:show_saga_modal, false)
      |> assign_filters()
      |> assign_sorting()

    send(self(), :load_sagas)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Sagas")
  end

  @impl true
  def handle_info(:load_sagas, socket) do
    {sagas, meta} = load_sagas(socket.assigns)

    socket =
      socket
      |> assign(:sagas, sagas)
      |> assign(:meta, meta)
      |> assign(:loading, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    socket =
      socket
      |> assign(:filters, Map.merge(socket.assigns.filters, filters))
      # Reset to first page when filtering
      |> assign(:page, 1)
      |> assign(:loading, true)

    send(self(), :load_sagas)

    {:noreply, socket}
  end

  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign_filters()
      |> assign(:loading, true)

    send(self(), :load_sagas)

    {:noreply, socket}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    current_sort_by = socket.assigns.sort_by
    current_sort_order = socket.assigns.sort_order

    # Toggle order if same field, otherwise default to desc
    new_sort_order =
      if field == current_sort_by and current_sort_order == :desc do
        :asc
      else
        :desc
      end

    socket =
      socket
      |> assign(:sort_by, String.to_atom(field))
      |> assign(:sort_order, new_sort_order)
      |> assign(:loading, true)

    send(self(), :load_sagas)

    {:noreply, socket}
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    socket =
      socket
      |> assign(:page, String.to_integer(page))
      |> assign(:loading, true)

    send(self(), :load_sagas)

    {:noreply, socket}
  end

  def handle_event("show_saga", %{"id" => saga_id}, socket) do
    case Sagas.get_saga_with_details(saga_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Saga not found")}

      saga ->
        socket =
          socket
          |> assign(:selected_saga, saga)
          |> assign(:show_saga_modal, true)

        {:noreply, socket}
    end
  end

  def handle_event("close_saga_modal", _params, socket) do
    socket =
      socket
      |> assign(:selected_saga, nil)
      |> assign(:show_saga_modal, false)

    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    socket =
      socket
      |> assign(:loading, true)

    send(self(), :load_sagas)

    {:noreply, socket}
  end

  # Helper functions

  defp assign_filters(socket) do
    assign(socket, :filters, %{
      "status" => "",
      "client_id" => "",
      "workflow_name" => "",
      "correlation_id" => ""
    })
  end

  defp assign_sorting(socket) do
    socket
    |> assign(:sort_by, :inserted_at)
    |> assign(:sort_order, :desc)
    |> assign(:page, 1)
    |> assign(:page_size, 20)
  end

  defp load_sagas(assigns) do
    opts = [
      status: filter_value(assigns.filters["status"]),
      client_id: filter_value(assigns.filters["client_id"]),
      workflow_name: filter_value(assigns.filters["workflow_name"]),
      correlation_id: filter_value(assigns.filters["correlation_id"]),
      page: assigns[:page] || 1,
      page_size: assigns[:page_size] || 20,
      sort_by: assigns[:sort_by] || :inserted_at,
      sort_order: assigns[:sort_order] || :desc
    ]

    Sagas.list_sagas(opts)
  end

  defp filter_value(""), do: nil
  defp filter_value(nil), do: nil
  defp filter_value(value), do: value

  # Status badge helpers

  defp status_badge_class("pending"), do: "bg-yellow-100 text-yellow-800"
  defp status_badge_class("running"), do: "bg-blue-100 text-blue-800"
  defp status_badge_class("completed"), do: "bg-green-100 text-green-800"
  defp status_badge_class("failed"), do: "bg-red-100 text-red-800"
  defp status_badge_class("compensating"), do: "bg-orange-100 text-orange-800"
  defp status_badge_class("compensated"), do: "bg-purple-100 text-purple-800"
  defp status_badge_class("paused"), do: "bg-gray-100 text-gray-800"
  defp status_badge_class(_), do: "bg-gray-100 text-gray-800"

  # Time helpers

  defp format_datetime(nil), do: "—"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  # Sort indicator helpers

  defp sort_indicator(field, current_field, current_order) do
    if field == current_field do
      case current_order do
        :asc -> "↑"
        :desc -> "↓"
      end
    else
      ""
    end
  end
end
