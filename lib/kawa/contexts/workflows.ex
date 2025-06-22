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

  @doc """
  Returns workflow definitions for a specific client.

  ## Examples

      iex> list_workflow_definitions_for_client(client_id)
      [%WorkflowDefinition{}, ...]

  """
  def list_workflow_definitions_for_client(client_id) do
    WorkflowDefinition
    |> where([w], w.client_id == ^client_id)
    |> preload(:client)
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns only active workflow definitions.

  ## Examples

      iex> list_active_workflow_definitions()
      [%WorkflowDefinition{}, ...]

  """
  def list_active_workflow_definitions do
    WorkflowDefinition
    |> where([w], w.is_active == true)
    |> preload(:client)
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single workflow definition by id.

  Returns `nil` if the WorkflowDefinition does not exist.

  ## Examples

      iex> get_workflow_definition(123)
      %WorkflowDefinition{}

      iex> get_workflow_definition(456)
      nil

  """
  def get_workflow_definition(id) do
    WorkflowDefinition
    |> preload(:client)
    |> Repo.get(id)
  end

  @doc """
  Gets a workflow definition by name and version for a specific client.

  Returns `nil` if the WorkflowDefinition does not exist.

  ## Examples

      iex> get_workflow_definition_by_name("my_workflow", "1.0.0", client_id)
      %WorkflowDefinition{}

      iex> get_workflow_definition_by_name("nonexistent", "1.0.0", client_id)
      nil

  """
  def get_workflow_definition_by_name(name, version, client_id) do
    WorkflowDefinition
    |> where([w], w.name == ^name and w.version == ^version and w.client_id == ^client_id)
    |> preload(:client)
    |> Repo.one()
  end

  @doc """
  Gets all versions of a workflow for a specific client.

  ## Examples

      iex> get_workflow_versions("my_workflow", client_id)
      [%WorkflowDefinition{}, ...]

  """
  def get_workflow_versions(name, client_id) do
    WorkflowDefinition
    |> where([w], w.name == ^name and w.client_id == ^client_id)
    |> preload(:client)
    |> order_by([w], desc: w.version)
    |> Repo.all()
  end

  @doc """
  Creates a workflow definition.

  ## Examples

      iex> create_workflow_definition(%{field: value})
      {:ok, %WorkflowDefinition{}}

      iex> create_workflow_definition(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_workflow_definition(attrs \\ %{}) do
    %WorkflowDefinition{}
    |> WorkflowDefinition.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a workflow definition.

  ## Examples

      iex> update_workflow_definition(workflow_definition, %{field: new_value})
      {:ok, %WorkflowDefinition{}}

      iex> update_workflow_definition(workflow_definition, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_workflow_definition(%WorkflowDefinition{} = workflow_definition, attrs) do
    workflow_definition
    |> WorkflowDefinition.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a workflow definition.

  ## Examples

      iex> delete_workflow_definition(workflow_definition)
      {:ok, %WorkflowDefinition{}}

      iex> delete_workflow_definition(workflow_definition)
      {:error, %Ecto.Changeset{}}

  """
  def delete_workflow_definition(%WorkflowDefinition{} = workflow_definition) do
    Repo.delete(workflow_definition)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking workflow definition changes.

  ## Examples

      iex> change_workflow_definition(workflow_definition)
      %Ecto.Changeset{data: %WorkflowDefinition{}}

  """
  def change_workflow_definition(%WorkflowDefinition{} = workflow_definition, attrs \\ %{}) do
    WorkflowDefinition.changeset(workflow_definition, attrs)
  end
end
