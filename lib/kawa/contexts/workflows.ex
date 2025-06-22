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

  def deactivate_previous_versions(current_workflow) do
    WorkflowDefinition
    |> where([w], w.name == ^current_workflow.name and w.version < ^current_workflow.version)
    |> Repo.update_all(set: [is_active: false])
  end

  @doc """
  Returns all versions of a workflow by name, ordered by version descending.

  ## Examples

      iex> list_workflow_versions("payment_workflow")
      [%WorkflowDefinition{version: "2.0.0"}, %WorkflowDefinition{version: "1.0.0"}]

  """
  def list_workflow_versions(workflow_name) do
    WorkflowDefinition
    |> where([w], w.name == ^workflow_name)
    |> preload(:client)
    |> order_by([w], desc: w.version)
    |> Repo.all()
  end
end
