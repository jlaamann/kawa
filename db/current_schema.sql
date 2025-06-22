--
-- PostgreSQL database dump
--

-- Dumped from database version 15.13 (Debian 15.13-1.pgdg120+1)
-- Dumped by pg_dump version 15.13 (Debian 15.13-1.pgdg120+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: next_saga_sequence_number(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.next_saga_sequence_number(p_saga_id uuid) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
  next_seq bigint;
BEGIN
  SELECT COALESCE(MAX(sequence_number), 0) + 1
  INTO next_seq
  FROM saga_events
  WHERE saga_id = p_saga_id;
  
  RETURN next_seq;
END;
$$;


ALTER FUNCTION public.next_saga_sequence_number(p_saga_id uuid) OWNER TO postgres;

--
-- Name: set_saga_event_sequence(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_saga_event_sequence() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.sequence_number IS NULL THEN
    NEW.sequence_number := next_saga_sequence_number(NEW.saga_id);
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_saga_event_sequence() OWNER TO postgres;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_updated_at_column() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: clients; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.clients (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying(255) NOT NULL,
    version character varying(50) DEFAULT '1.0.0'::character varying NOT NULL,
    status character varying(20) DEFAULT 'disconnected'::character varying NOT NULL,
    last_heartbeat_at timestamp(0) without time zone,
    connection_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    capabilities jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_metrics jsonb DEFAULT '{}'::jsonb NOT NULL,
    heartbeat_interval_ms integer DEFAULT 30000 NOT NULL,
    registered_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    api_key_hash character varying(255) NOT NULL,
    environment character varying(20) DEFAULT 'dev'::character varying NOT NULL,
    api_key_prefix character varying(8) NOT NULL,
    CONSTRAINT clients_environment_check CHECK (((environment)::text = ANY ((ARRAY['dev'::character varying, 'staging'::character varying, 'prod'::character varying])::text[]))),
    CONSTRAINT clients_heartbeat_interval_check CHECK ((heartbeat_interval_ms > 0)),
    CONSTRAINT clients_name_length_check CHECK ((length((name)::text) > 0)),
    CONSTRAINT clients_status_check CHECK (((status)::text = ANY ((ARRAY['connected'::character varying, 'disconnected'::character varying, 'error'::character varying])::text[])))
);


ALTER TABLE public.clients OWNER TO postgres;

--
-- Name: TABLE clients; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.clients IS 'Client applications that register workflows and execute steps';


--
-- Name: saga_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.saga_events (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    saga_id uuid NOT NULL,
    sequence_number bigint NOT NULL,
    event_type character varying(50) NOT NULL,
    step_id character varying(100),
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    before_state jsonb,
    after_state jsonb,
    duration_ms integer,
    occurred_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT saga_events_duration_check CHECK (((duration_ms IS NULL) OR (duration_ms >= 0))),
    CONSTRAINT saga_events_event_type_length_check CHECK ((length((event_type)::text) > 0))
);


ALTER TABLE public.saga_events OWNER TO postgres;

--
-- Name: TABLE saga_events; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.saga_events IS 'Event sourcing log for saga lifecycle events';


--
-- Name: COLUMN saga_events.sequence_number; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.saga_events.sequence_number IS 'Auto-incrementing sequence per saga for event ordering';


--
-- Name: saga_steps; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.saga_steps (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    saga_id uuid NOT NULL,
    step_id character varying(100) NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    step_type character varying(20) DEFAULT 'action'::character varying NOT NULL,
    input jsonb DEFAULT '{}'::jsonb NOT NULL,
    output jsonb DEFAULT '{}'::jsonb NOT NULL,
    error_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    started_at timestamp(0) without time zone,
    completed_at timestamp(0) without time zone,
    timeout_at timestamp(0) without time zone,
    retry_count integer DEFAULT 0 NOT NULL,
    depends_on character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    execution_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT saga_steps_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT saga_steps_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'running'::character varying, 'completed'::character varying, 'failed'::character varying, 'compensating'::character varying, 'compensated'::character varying, 'skipped'::character varying])::text[]))),
    CONSTRAINT saga_steps_step_id_length_check CHECK ((length((step_id)::text) > 0)),
    CONSTRAINT saga_steps_step_type_check CHECK (((step_type)::text = ANY ((ARRAY['action'::character varying, 'compensation'::character varying])::text[])))
);


ALTER TABLE public.saga_steps OWNER TO postgres;

--
-- Name: TABLE saga_steps; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.saga_steps IS 'Individual step executions within sagas';


--
-- Name: sagas; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sagas (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    workflow_definition_id uuid NOT NULL,
    client_id uuid NOT NULL,
    correlation_id character varying(255) NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    input jsonb DEFAULT '{}'::jsonb NOT NULL,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    started_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    completed_at timestamp(0) without time zone,
    paused_at timestamp(0) without time zone,
    timeout_at timestamp(0) without time zone,
    total_retry_count integer DEFAULT 0 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT sagas_correlation_id_length_check CHECK ((length((correlation_id)::text) > 0)),
    CONSTRAINT sagas_retry_count_check CHECK ((total_retry_count >= 0)),
    CONSTRAINT sagas_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'running'::character varying, 'paused'::character varying, 'completed'::character varying, 'failed'::character varying, 'compensating'::character varying, 'compensated'::character varying])::text[])))
);


ALTER TABLE public.sagas OWNER TO postgres;

--
-- Name: TABLE sagas; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.sagas IS 'Individual workflow executions';


--
-- Name: COLUMN sagas.correlation_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sagas.correlation_id IS 'User-provided identifier for external tracking';


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


ALTER TABLE public.schema_migrations OWNER TO postgres;

--
-- Name: workflow_definitions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.workflow_definitions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying(255) NOT NULL,
    version character varying(50) DEFAULT '1.0.0'::character varying NOT NULL,
    client_id uuid NOT NULL,
    module_name character varying(500) NOT NULL,
    definition jsonb NOT NULL,
    definition_checksum character varying(64) NOT NULL,
    default_timeout_ms integer DEFAULT 300000 NOT NULL,
    default_retry_policy jsonb DEFAULT '{"backoff_ms": 1000, "max_retries": 3}'::jsonb NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    validation_errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    registered_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT workflow_definitions_module_length_check CHECK ((length((module_name)::text) > 0)),
    CONSTRAINT workflow_definitions_name_length_check CHECK ((length((name)::text) > 0)),
    CONSTRAINT workflow_definitions_timeout_check CHECK ((default_timeout_ms > 0))
);


ALTER TABLE public.workflow_definitions OWNER TO postgres;

--
-- Name: TABLE workflow_definitions; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.workflow_definitions IS 'Workflow templates registered by clients';


--
-- Name: COLUMN workflow_definitions.definition_checksum; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.workflow_definitions.definition_checksum IS 'MD5 hash for detecting workflow changes';


--
-- Name: clients clients_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_pkey PRIMARY KEY (id);


--
-- Name: saga_events saga_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.saga_events
    ADD CONSTRAINT saga_events_pkey PRIMARY KEY (id);


--
-- Name: saga_steps saga_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.saga_steps
    ADD CONSTRAINT saga_steps_pkey PRIMARY KEY (id);


--
-- Name: sagas sagas_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sagas
    ADD CONSTRAINT sagas_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: workflow_definitions workflow_definitions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.workflow_definitions
    ADD CONSTRAINT workflow_definitions_pkey PRIMARY KEY (id);


--
-- Name: idx_clients_heartbeat; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_clients_heartbeat ON public.clients USING btree (last_heartbeat_at) WHERE ((status)::text = 'connected'::text);


--
-- Name: idx_clients_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_clients_status ON public.clients USING btree (status) WHERE ((status)::text = 'connected'::text);


--
-- Name: idx_saga_events_event_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_saga_events_event_type ON public.saga_events USING btree (event_type);


--
-- Name: idx_saga_events_occurred_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_saga_events_occurred_at ON public.saga_events USING btree (occurred_at);


--
-- Name: idx_saga_events_saga_sequence; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_saga_events_saga_sequence ON public.saga_events USING btree (saga_id, sequence_number);


--
-- Name: idx_saga_steps_saga_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_saga_steps_saga_status ON public.saga_steps USING btree (saga_id, status);


--
-- Name: idx_saga_steps_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_saga_steps_status ON public.saga_steps USING btree (status) WHERE ((status)::text = ANY ((ARRAY['running'::character varying, 'failed'::character varying])::text[]));


--
-- Name: idx_sagas_client_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sagas_client_status ON public.sagas USING btree (client_id, status);


--
-- Name: idx_sagas_correlation_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sagas_correlation_id ON public.sagas USING btree (correlation_id);


--
-- Name: idx_sagas_started_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sagas_started_at ON public.sagas USING btree (started_at);


--
-- Name: idx_sagas_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sagas_status ON public.sagas USING btree (status) WHERE ((status)::text = ANY ((ARRAY['running'::character varying, 'paused'::character varying])::text[]));


--
-- Name: idx_sagas_timeout; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sagas_timeout ON public.sagas USING btree (timeout_at) WHERE (timeout_at IS NOT NULL);


--
-- Name: idx_workflow_definitions_client_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_workflow_definitions_client_active ON public.workflow_definitions USING btree (client_id, is_active);


--
-- Name: idx_workflow_definitions_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_workflow_definitions_name ON public.workflow_definitions USING btree (name);


--
-- Name: uk_clients_api_key_hash; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uk_clients_api_key_hash ON public.clients USING btree (api_key_hash);


--
-- Name: uk_clients_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uk_clients_name ON public.clients USING btree (name);


--
-- Name: uk_saga_events_saga_sequence; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uk_saga_events_saga_sequence ON public.saga_events USING btree (saga_id, sequence_number);


--
-- Name: uk_saga_steps_saga_step_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uk_saga_steps_saga_step_type ON public.saga_steps USING btree (saga_id, step_id, step_type);


--
-- Name: uk_sagas_correlation_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uk_sagas_correlation_id ON public.sagas USING btree (correlation_id);


--
-- Name: uk_workflow_definitions_client_name_version; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uk_workflow_definitions_client_name_version ON public.workflow_definitions USING btree (client_id, name, version);


--
-- Name: clients trigger_clients_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_clients_updated_at BEFORE UPDATE ON public.clients FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: saga_steps trigger_saga_steps_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_saga_steps_updated_at BEFORE UPDATE ON public.saga_steps FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: sagas trigger_sagas_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_sagas_updated_at BEFORE UPDATE ON public.sagas FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: saga_events trigger_set_saga_event_sequence; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_set_saga_event_sequence BEFORE INSERT ON public.saga_events FOR EACH ROW EXECUTE FUNCTION public.set_saga_event_sequence();


--
-- Name: workflow_definitions trigger_workflow_definitions_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_workflow_definitions_updated_at BEFORE UPDATE ON public.workflow_definitions FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: saga_events saga_events_saga_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.saga_events
    ADD CONSTRAINT saga_events_saga_id_fkey FOREIGN KEY (saga_id) REFERENCES public.sagas(id) ON DELETE CASCADE;


--
-- Name: saga_steps saga_steps_saga_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.saga_steps
    ADD CONSTRAINT saga_steps_saga_id_fkey FOREIGN KEY (saga_id) REFERENCES public.sagas(id) ON DELETE CASCADE;


--
-- Name: sagas sagas_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sagas
    ADD CONSTRAINT sagas_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE RESTRICT;


--
-- Name: sagas sagas_workflow_definition_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sagas
    ADD CONSTRAINT sagas_workflow_definition_id_fkey FOREIGN KEY (workflow_definition_id) REFERENCES public.workflow_definitions(id) ON DELETE RESTRICT;


--
-- Name: workflow_definitions workflow_definitions_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.workflow_definitions
    ADD CONSTRAINT workflow_definitions_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

