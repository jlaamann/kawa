defmodule Kawa.Repo.Migrations.AddSagaFunctionsAndTriggers do
  use Ecto.Migration

  def up do
    # Function to auto-increment sequence_number per saga
    execute """
    CREATE OR REPLACE FUNCTION next_saga_sequence_number(p_saga_id uuid)
    RETURNS bigint AS $$
    DECLARE
      next_seq bigint;
    BEGIN
      SELECT COALESCE(MAX(sequence_number), 0) + 1
      INTO next_seq
      FROM saga_events
      WHERE saga_id = p_saga_id;
      
      RETURN next_seq;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Trigger function to auto-set sequence_number
    execute """
    CREATE OR REPLACE FUNCTION set_saga_event_sequence()
    RETURNS TRIGGER AS $$
    BEGIN
      IF NEW.sequence_number IS NULL THEN
        NEW.sequence_number := next_saga_sequence_number(NEW.saga_id);
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Create trigger for saga_events
    execute """
    CREATE TRIGGER trigger_set_saga_event_sequence
      BEFORE INSERT ON saga_events
      FOR EACH ROW
      EXECUTE FUNCTION set_saga_event_sequence();
    """

    # Function to update updated_at timestamp
    execute """
    CREATE OR REPLACE FUNCTION update_updated_at_column()
    RETURNS TRIGGER AS $$
    BEGIN
      NEW.updated_at = now();
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Apply updated_at triggers to all tables that have updated_at
    execute """
    CREATE TRIGGER trigger_clients_updated_at
      BEFORE UPDATE ON clients
      FOR EACH ROW
      EXECUTE FUNCTION update_updated_at_column();
    """

    execute """
    CREATE TRIGGER trigger_workflow_definitions_updated_at
      BEFORE UPDATE ON workflow_definitions
      FOR EACH ROW
      EXECUTE FUNCTION update_updated_at_column();
    """

    execute """
    CREATE TRIGGER trigger_sagas_updated_at
      BEFORE UPDATE ON sagas
      FOR EACH ROW
      EXECUTE FUNCTION update_updated_at_column();
    """

    execute """
    CREATE TRIGGER trigger_saga_steps_updated_at
      BEFORE UPDATE ON saga_steps
      FOR EACH ROW
      EXECUTE FUNCTION update_updated_at_column();
    """

    execute """
    CREATE TRIGGER trigger_workflow_steps_updated_at
      BEFORE UPDATE ON workflow_steps
      FOR EACH ROW
      EXECUTE FUNCTION update_updated_at_column();
    """

    # Add table comments for documentation
    execute "COMMENT ON TABLE clients IS 'Client applications that register workflows and execute steps'"
    execute "COMMENT ON TABLE workflow_definitions IS 'Workflow templates registered by clients'"
    execute "COMMENT ON TABLE sagas IS 'Individual workflow executions'"
    execute "COMMENT ON TABLE workflow_steps IS 'Step definitions within workflow templates'"
    execute "COMMENT ON TABLE saga_steps IS 'Individual step executions within sagas'"
    execute "COMMENT ON TABLE saga_events IS 'Event sourcing log for saga lifecycle events'"

    # Add column comments
    execute "COMMENT ON COLUMN sagas.correlation_id IS 'User-provided identifier for external tracking'"

    execute "COMMENT ON COLUMN saga_events.sequence_number IS 'Auto-incrementing sequence per saga for event ordering'"

    execute "COMMENT ON COLUMN workflow_definitions.definition_checksum IS 'MD5 hash for detecting workflow changes'"
  end

  def down do
    # Drop triggers
    execute "DROP TRIGGER IF EXISTS trigger_set_saga_event_sequence ON saga_events"
    execute "DROP TRIGGER IF EXISTS trigger_clients_updated_at ON clients"

    execute "DROP TRIGGER IF EXISTS trigger_workflow_definitions_updated_at ON workflow_definitions"

    execute "DROP TRIGGER IF EXISTS trigger_sagas_updated_at ON sagas"
    execute "DROP TRIGGER IF EXISTS trigger_saga_steps_updated_at ON saga_steps"
    execute "DROP TRIGGER IF EXISTS trigger_workflow_steps_updated_at ON workflow_steps"

    # Drop functions
    execute "DROP FUNCTION IF EXISTS next_saga_sequence_number(uuid)"
    execute "DROP FUNCTION IF EXISTS set_saga_event_sequence()"
    execute "DROP FUNCTION IF EXISTS update_updated_at_column()"
  end
end
