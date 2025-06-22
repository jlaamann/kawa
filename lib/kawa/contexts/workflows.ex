defmodule Kawa.Contexts.Workflows do
  @moduledoc """
  Context module for WorkflowDefinition database operations.

  Provides functions to query, create, and manage workflow definitions
  stored in the database.
  """

  import Ecto.Query, warn: false
  alias Kawa.Repo
  alias Kawa.Schemas.WorkflowDefinition

  @doc """
  Returns all workflow definitions from the database.

  ## Examples

      iex> list_workflow_definitions()
      [%WorkflowDefinition{}, ...]

  """
  def list_workflow_definitions do
    WorkflowDefinition
    |> preload(:client)
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
  end
end
