-- ADR-009 / PRD-13. Optional, host-owned PostgreSQL schema, PostgreSQL 14+.
-- Install through Liquibase as an administrative role. No network occurs here.
DO $roles$
DECLARE role_name text;
BEGIN
  FOREACH role_name IN ARRAY ARRAY['mcp_sync_owner','mcp_sync_apply','mcp_sync_worker','mcp_sync_client'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = role_name) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', role_name);
    END IF;
  END LOOP;
END $roles$;

CREATE SCHEMA mcp_sync AUTHORIZATION mcp_sync_owner;
REVOKE ALL ON SCHEMA mcp_sync FROM PUBLIC;
GRANT USAGE ON SCHEMA mcp_sync TO mcp_sync_apply, mcp_sync_worker, mcp_sync_client;

CREATE TABLE mcp_sync.bindings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id text NOT NULL,
  source_id text NOT NULL,
  source_binding_id uuid,
  principal_id text NOT NULL,
  relation text NOT NULL,
  app_role name NOT NULL,
  credential_ref text,
  access_mode text NOT NULL DEFAULT 'read_only' CHECK (access_mode IN ('read_only','read_write')),
  capabilities jsonb NOT NULL DEFAULT '{}',
  enabled boolean NOT NULL DEFAULT true,
  UNIQUE (tenant_id, source_id, principal_id, relation),
  CHECK (access_mode <> 'read_write' OR (
    capabilities @> '{"version":1,"conditionalWrites":true,"idempotency":true,"changes":true,"snapshot":"consistent"}'
    AND COALESCE((capabilities->>'idempotencyRetentionSeconds')::bigint,0) > 0
    AND COALESCE((capabilities->>'changeRetentionSeconds')::bigint,0) > 0
  ))
);
CREATE TABLE mcp_sync.records (
  binding_id uuid NOT NULL REFERENCES mcp_sync.bindings(id),
  resource_key jsonb NOT NULL CHECK (jsonb_typeof(resource_key)='object' AND resource_key<>'{}'::jsonb),
  payload jsonb,
  source_revision text,
  source_counter bigint NOT NULL DEFAULT 0,
  local_revision bigint NOT NULL DEFAULT 0 CHECK (local_revision > 0),
  deleted boolean NOT NULL DEFAULT false,
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('clean','pending','conflict','blocked','tombstone')),
  expected_local_revision bigint,
  last_origin text NOT NULL DEFAULT 'local' CHECK (last_origin IN ('local','remote')),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  checked_at timestamptz,
  CHECK (deleted OR COALESCE(jsonb_typeof(payload)='object',false)),
  PRIMARY KEY(binding_id,resource_key)
);
CREATE INDEX records_binding_state ON mcp_sync.records(binding_id,state,updated_at);
CREATE INDEX records_payload ON mcp_sync.records USING gin(payload jsonb_path_ops);
CREATE TABLE mcp_sync.outbox (
  operation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  binding_id uuid NOT NULL,
  resource_key jsonb NOT NULL,
  queued_local_revision bigint NOT NULL,
  operation text NOT NULL CHECK(operation IN ('create','update','delete')),
  precondition jsonb NOT NULL,
  payload jsonb,
  request_hash text NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','claimed','unknown','conflict','blocked','acknowledged','resolved')),
  attempts integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_until timestamptz,
  fencing_token bigint NOT NULL DEFAULT 0,
  first_attempt_at timestamptz,
  last_error text,
  outcome jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY(binding_id,resource_key) REFERENCES mcp_sync.records(binding_id,resource_key)
);
CREATE UNIQUE INDEX outbox_one_pending ON mcp_sync.outbox(binding_id,resource_key)
 WHERE state IN ('pending','claimed','unknown','conflict','blocked');
CREATE INDEX outbox_due ON mcp_sync.outbox(binding_id,next_attempt_at,operation_id)
 WHERE state IN ('pending','unknown','claimed');
CREATE TABLE mcp_sync.checkpoints (
 binding_id uuid PRIMARY KEY REFERENCES mcp_sync.bindings(id),
 source_cursor text, last_event_id bigint NOT NULL DEFAULT 0, snapshot_id text,
 last_success_at timestamptz, status text NOT NULL DEFAULT 'new'
);
CREATE TABLE mcp_sync.inbound_deferred (
 binding_id uuid NOT NULL REFERENCES mcp_sync.bindings(id), event_id bigint NOT NULL,
 resource_key jsonb NOT NULL, event jsonb NOT NULL,
 observed_at timestamptz NOT NULL DEFAULT clock_timestamp(), applied_at timestamptz,
 PRIMARY KEY(binding_id,event_id)
);
CREATE TABLE mcp_sync.conflicts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), binding_id uuid NOT NULL,
 resource_key jsonb NOT NULL, operation_id uuid NOT NULL REFERENCES mcp_sync.outbox(operation_id),
 base_revision text, remote_revision text, local_payload jsonb, remote_evidence jsonb,
 reason text NOT NULL, state text NOT NULL DEFAULT 'open' CHECK(state IN ('open','resolved')),
 resolution text, created_at timestamptz NOT NULL DEFAULT clock_timestamp(), resolved_at timestamptz,
 FOREIGN KEY(binding_id,resource_key) REFERENCES mcp_sync.records(binding_id,resource_key)
);
CREATE UNIQUE INDEX conflicts_one_open ON mcp_sync.conflicts(operation_id) WHERE state='open';
CREATE TABLE mcp_sync.source_heads (
 binding_id uuid PRIMARY KEY REFERENCES mcp_sync.bindings(id),
 counter bigint NOT NULL DEFAULT 0, retained_after bigint NOT NULL DEFAULT 0
);
CREATE TABLE mcp_sync.source_records (
 binding_id uuid NOT NULL REFERENCES mcp_sync.bindings(id), resource_key jsonb NOT NULL,
 payload jsonb, revision text NOT NULL, deleted boolean NOT NULL,
 counter bigint NOT NULL, PRIMARY KEY(binding_id,resource_key)
);
CREATE TABLE mcp_sync.source_changes (
 binding_id uuid NOT NULL REFERENCES mcp_sync.bindings(id), counter bigint NOT NULL,
 event jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(binding_id,counter)
);
CREATE TABLE mcp_sync.source_operations (
 binding_id uuid NOT NULL REFERENCES mcp_sync.bindings(id), operation_id uuid NOT NULL,
 request_hash text NOT NULL, outcome jsonb NOT NULL,
 retain_until timestamptz NOT NULL, PRIMARY KEY(binding_id,operation_id)
);
CREATE TABLE mcp_sync.source_snapshots (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), binding_id uuid NOT NULL REFERENCES mcp_sync.bindings(id),
 rows jsonb NOT NULL, change_cursor text NOT NULL,
 expires_at timestamptz NOT NULL DEFAULT (clock_timestamp()+interval '15 minutes')
);

-- Owner/apply identities are NOLOGIN and are never granted to applications.
DO $owners$
DECLARE relation_name text;
BEGIN
 FOR relation_name IN SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='mcp_sync' LOOP
  EXECUTE format('ALTER TABLE mcp_sync.%I OWNER TO mcp_sync_owner',relation_name);
  EXECUTE format('ALTER TABLE mcp_sync.%I ENABLE ROW LEVEL SECURITY',relation_name);
  EXECUTE format('ALTER TABLE mcp_sync.%I FORCE ROW LEVEL SECURITY',relation_name);
  EXECUTE format('CREATE POLICY internal_access ON mcp_sync.%I TO mcp_sync_owner,mcp_sync_apply USING (true) WITH CHECK (true)',relation_name);
 END LOOP;
END $owners$;

CREATE FUNCTION mcp_sync._can_access(p_binding uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM mcp_sync.bindings b WHERE b.id=p_binding AND b.enabled
   AND (b.app_role=session_user OR pg_has_role(session_user,'mcp_sync_worker','member')))
$$;
CREATE FUNCTION mcp_sync._assert_access(p_binding uuid,p_write boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE b mcp_sync.bindings;
BEGIN
 SELECT * INTO b FROM mcp_sync.bindings WHERE id=p_binding;
 IF p_write THEN
  SELECT * INTO b FROM mcp_sync.bindings WHERE id=p_binding FOR SHARE;
 END IF;
 IF NOT FOUND OR NOT mcp_sync._can_access(p_binding) THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='permission_denied';
 END IF;
 IF p_write AND b.access_mode <> 'read_write' THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='unsupported_consistency';
 END IF;
END $$;
CREATE FUNCTION mcp_sync._assert_worker() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT pg_has_role(session_user,'mcp_sync_worker','member') THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='permission_denied';
 END IF;
END $$;

CREATE POLICY binding_reader ON mcp_sync.bindings TO mcp_sync_client,mcp_sync_worker
 USING(mcp_sync._can_access(id));
DO $policies$
DECLARE relation_name text;
BEGIN
 FOREACH relation_name IN ARRAY ARRAY['records','outbox','checkpoints','inbound_deferred','conflicts'] LOOP
  EXECUTE format('CREATE POLICY binding_access ON mcp_sync.%I TO mcp_sync_client,mcp_sync_worker USING(mcp_sync._can_access(binding_id)) WITH CHECK(mcp_sync._can_access(binding_id))',relation_name);
 END LOOP;
END $policies$;

CREATE FUNCTION mcp_sync._record_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF TG_OP='DELETE' THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='physical_delete_denied';
 END IF;
 IF jsonb_typeof(NEW.resource_key) IS DISTINCT FROM 'object' OR NEW.resource_key='{}'::jsonb
    OR (NOT NEW.deleted AND jsonb_typeof(NEW.payload) IS DISTINCT FROM 'object') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request';
 END IF;
 IF current_user='mcp_sync_apply' THEN
  NEW.expected_local_revision=NULL; NEW.last_origin='remote'; RETURN NEW;
 END IF;
 PERFORM mcp_sync._assert_access(NEW.binding_id,true);
 IF TG_OP='INSERT' THEN
  IF NEW.expected_local_revision IS DISTINCT FROM 0 OR NEW.source_revision IS NOT NULL
     OR NEW.local_revision<>0 OR NEW.deleted THEN
   RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='revision_conflict';
  END IF;
  NEW.local_revision=1;
 ELSE
  IF (NEW.binding_id,NEW.resource_key,NEW.source_revision,NEW.source_counter,NEW.local_revision,NEW.state,NEW.checked_at,NEW.last_origin)
       IS DISTINCT FROM (OLD.binding_id,OLD.resource_key,OLD.source_revision,OLD.source_counter,OLD.local_revision,OLD.state,OLD.checked_at,OLD.last_origin) THEN
   RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='metadata_change_denied';
  END IF;
  IF NEW.expected_local_revision IS NULL OR NEW.expected_local_revision<>OLD.local_revision THEN
   RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='revision_conflict';
  END IF;
  IF OLD.state NOT IN ('clean','tombstone') THEN
   RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='operation_pending';
  END IF;
  NEW.local_revision=OLD.local_revision+1;
 END IF;
 NEW.expected_local_revision=NULL; NEW.last_origin='local'; NEW.state='pending';
 NEW.updated_at=clock_timestamp();
 RETURN NEW;
END $$;
CREATE FUNCTION mcp_sync._enqueue_record() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE operation text; precondition jsonb;
BEGIN
 IF NEW.last_origin='remote' THEN RETURN NEW; END IF;
 operation=CASE WHEN NEW.deleted THEN 'delete' WHEN TG_OP='INSERT' THEN 'create' ELSE 'update' END;
 precondition=CASE WHEN TG_OP='INSERT' THEN '{"absent":true}'::jsonb ELSE jsonb_build_object('revision',OLD.source_revision) END;
 INSERT INTO mcp_sync.outbox(binding_id,resource_key,queued_local_revision,operation,precondition,payload,request_hash)
 VALUES(NEW.binding_id,NEW.resource_key,NEW.local_revision,operation,precondition,NEW.payload,
  encode(sha256(convert_to(jsonb_build_object('key',NEW.resource_key,'operation',operation,'precondition',precondition,'value',NEW.payload)::text,'UTF8')),'hex'));
 RETURN NEW;
END $$;
CREATE TRIGGER records_guard BEFORE INSERT OR UPDATE OR DELETE ON mcp_sync.records
 FOR EACH ROW EXECUTE FUNCTION mcp_sync._record_guard();
CREATE TRIGGER records_enqueue AFTER INSERT OR UPDATE ON mcp_sync.records
 FOR EACH ROW EXECUTE FUNCTION mcp_sync._enqueue_record();

CREATE FUNCTION mcp_sync.put(p_binding uuid,p_key jsonb,p_payload jsonb,p_expected bigint) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE r mcp_sync.records; op uuid;
BEGIN
 PERFORM mcp_sync._assert_access(p_binding,true);
 IF p_expected=0 THEN
  BEGIN
   INSERT INTO mcp_sync.records(binding_id,resource_key,payload,expected_local_revision)
   VALUES(p_binding,p_key,p_payload,0) RETURNING * INTO r;
  EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='revision_conflict'; END;
 ELSE
  UPDATE mcp_sync.records SET payload=p_payload,deleted=false,expected_local_revision=p_expected
   WHERE binding_id=p_binding AND resource_key=p_key RETURNING * INTO r;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='revision_conflict'; END IF;
 END IF;
 SELECT operation_id INTO op FROM mcp_sync.outbox WHERE binding_id=p_binding AND resource_key=p_key AND state='pending';
 RETURN jsonb_build_object('localRevision',r.local_revision,'state',r.state,'operationId',op);
END $$;
CREATE FUNCTION mcp_sync.remove(p_binding uuid,p_key jsonb,p_expected bigint) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE r mcp_sync.records; op uuid;
BEGIN
 PERFORM mcp_sync._assert_access(p_binding,true);
 UPDATE mcp_sync.records SET deleted=true,expected_local_revision=p_expected
 WHERE binding_id=p_binding AND resource_key=p_key RETURNING * INTO r;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='revision_conflict'; END IF;
 SELECT operation_id INTO op FROM mcp_sync.outbox WHERE binding_id=p_binding AND resource_key=p_key AND state='pending';
 RETURN jsonb_build_object('localRevision',r.local_revision,'state',r.state,'operationId',op);
END $$;

-- Remaining worker/source functions follow below. Privileges installed last.
CREATE FUNCTION mcp_sync.source_capabilities(p_binding uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE rel text;
BEGIN
 PERFORM mcp_sync._assert_access(p_binding);
 SELECT relation INTO rel FROM mcp_sync.bindings WHERE id=p_binding;
 RETURN jsonb_build_object('version',1,'relation',rel,'primaryKey',jsonb_build_array('id'),
  'snapshot','consistent','changes',true,'conditionalWrites',true,'idempotency',true,
  'idempotencyRetentionSeconds',604800,'changeRetentionSeconds',604800,'maxPageSize',500);
END $$;

CREATE FUNCTION mcp_sync.source_mutate(p_binding uuid,p_request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE b mcp_sync.bindings; r mcp_sync.source_records; prior mcp_sync.source_operations;
 op uuid; key jsonb; kind text; expected jsonb; fingerprint text; seq bigint; revision text; result jsonb; present boolean;
BEGIN
 PERFORM mcp_sync._assert_access(p_binding,true);
 SELECT * INTO b FROM mcp_sync.bindings WHERE id=p_binding;
 key=p_request->'key';kind=p_request->>'operation';expected=p_request->'precondition';
 IF jsonb_typeof(key) IS DISTINCT FROM 'object' OR NOT key ? 'id' OR key IS DISTINCT FROM jsonb_build_object('id',key->'id')
   OR kind IS NULL OR kind NOT IN ('create','update','delete')
   OR p_request->>'relation' IS DISTINCT FROM b.relation
   OR (kind<>'delete' AND jsonb_typeof(p_request->'value') IS DISTINCT FROM 'object')
   OR (kind='create' AND expected IS DISTINCT FROM '{"absent":true}'::jsonb)
   OR (kind IN ('update','delete') AND (jsonb_typeof(expected->'revision') IS DISTINCT FROM 'string'
       OR expected->>'revision'='' OR expected IS DISTINCT FROM jsonb_build_object('revision',expected->'revision'))) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request';
 END IF;
 BEGIN op=(p_request->>'operationId')::uuid;
 EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request'; END;
 IF op IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request'; END IF;
 fingerprint=encode(sha256(convert_to(p_request::text,'UTF8')),'hex');
 INSERT INTO mcp_sync.source_heads(binding_id) VALUES(p_binding) ON CONFLICT DO NOTHING;
 PERFORM 1 FROM mcp_sync.source_heads WHERE binding_id=p_binding FOR UPDATE;
 SELECT * INTO prior FROM mcp_sync.source_operations WHERE binding_id=p_binding AND operation_id=op;
 IF FOUND THEN
  IF prior.request_hash<>fingerprint THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='idempotency_mismatch';
  END IF;
  RETURN prior.outcome;
 END IF;
 SELECT * INTO r FROM mcp_sync.source_records WHERE binding_id=p_binding AND resource_key=key FOR UPDATE;
 present=FOUND;
 IF (kind='create' AND (present OR expected IS DISTINCT FROM '{"absent":true}'::jsonb))
   OR (kind<>'create' AND (NOT present OR expected->>'revision' IS DISTINCT FROM r.revision
       OR expected->>'revision' IS NULL)) THEN
  RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='revision_conflict',
   DETAIL=jsonb_build_object('key',key,'revision',r.revision,'value',r.payload,
     'deleted',COALESCE(r.deleted,true),'eventId',COALESCE(r.counter,0)::text)::text;
 END IF;
 UPDATE mcp_sync.source_heads SET counter=counter+1 WHERE binding_id=p_binding RETURNING counter INTO seq;
 revision=gen_random_uuid()::text;
 result=jsonb_build_object('operationId',op,'key',key,'revision',revision,
   'value',CASE WHEN kind='delete' THEN NULL ELSE p_request->'value' END,
   'deleted',kind='delete','eventId',seq::text);
 INSERT INTO mcp_sync.source_records(binding_id,resource_key,payload,revision,deleted,counter)
 VALUES(p_binding,key,result->'value',revision,kind='delete',seq)
 ON CONFLICT(binding_id,resource_key) DO UPDATE
 SET payload=EXCLUDED.payload,revision=EXCLUDED.revision,deleted=EXCLUDED.deleted,counter=EXCLUDED.counter;
 INSERT INTO mcp_sync.source_changes(binding_id,counter,event) VALUES(p_binding,seq,result);
 INSERT INTO mcp_sync.source_operations(binding_id,operation_id,request_hash,outcome,retain_until)
 VALUES(p_binding,op,fingerprint,result,clock_timestamp()+interval '7 days');
 RETURN result;
END $$;

CREATE FUNCTION mcp_sync.source_operation(p_binding uuid,p_operation text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 PERFORM mcp_sync._assert_access(p_binding);
 SELECT outcome INTO result FROM mcp_sync.source_operations WHERE binding_id=p_binding AND operation_id=p_operation::uuid;
 RETURN COALESCE(result,'{"status":"unknown"}'::jsonb);
EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request';
END $$;

CREATE FUNCTION mcp_sync._cursor_counter(p_binding uuid,p_cursor text) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
BEGIN
 IF p_cursor IS NULL OR p_cursor='' THEN RETURN 0; END IF;
 IF split_part(p_cursor,':',1)<>'sync' OR split_part(p_cursor,':',2)<>p_binding::text
   OR p_cursor !~ '^sync:[0-9a-f-]+:[0-9]+$' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request';
 END IF;
 RETURN split_part(p_cursor,':',3)::bigint;
END $$;

CREATE FUNCTION mcp_sync._cache_cursor_counter(p_binding uuid,p_cursor text) RETURNS bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE source_binding uuid;
BEGIN
 SELECT COALESCE(source_binding_id,id) INTO source_binding FROM mcp_sync.bindings WHERE id=p_binding;
 RETURN mcp_sync._cursor_counter(source_binding,p_cursor);
END $$;

CREATE FUNCTION mcp_sync.source_changes(p_binding uuid,p_cursor text,p_limit int DEFAULT 500) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE after_counter bigint; retained bigint; head bigint; events jsonb; next_counter bigint; more boolean;
BEGIN
 PERFORM mcp_sync._assert_access(p_binding);
 IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request'; END IF;
 after_counter=mcp_sync._cursor_counter(p_binding,p_cursor);
 SELECT counter,retained_after INTO head,retained FROM mcp_sync.source_heads WHERE binding_id=p_binding;
 IF after_counter<COALESCE(retained,0) THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='resnapshot_required'; END IF;
 IF after_counter>COALESCE(head,0) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request'; END IF;
 SELECT COALESCE(jsonb_agg(event ORDER BY counter),'[]'),COALESCE(max(counter),after_counter)
 INTO events,next_counter FROM (SELECT counter,event FROM mcp_sync.source_changes
   WHERE binding_id=p_binding AND counter>after_counter ORDER BY counter LIMIT p_limit) page;
 SELECT EXISTS(SELECT 1 FROM mcp_sync.source_changes WHERE binding_id=p_binding AND counter>next_counter) INTO more;
 RETURN jsonb_build_object('events',events,'nextCursor','sync:'||p_binding::text||':'||next_counter::text,'hasMore',more);
END $$;

CREATE FUNCTION mcp_sync.source_snapshot(p_binding uuid,p_cursor text DEFAULT NULL,p_limit int DEFAULT 500) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE snapshot mcp_sync.source_snapshots; seq bigint; page_offset int=0; page jsonb; next_cursor text;
BEGIN
 PERFORM mcp_sync._assert_access(p_binding);
 IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request'; END IF;
 IF p_cursor IS NULL THEN
  INSERT INTO mcp_sync.source_heads(binding_id) VALUES(p_binding) ON CONFLICT DO NOTHING;
  -- All source writers lock head before records. This lock gives one consistent
  -- data/boundary capture even under READ COMMITTED; pages are materialized once.
  SELECT counter INTO seq FROM mcp_sync.source_heads WHERE binding_id=p_binding FOR SHARE;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('key',resource_key,'revision',revision,
    'value',payload,'deleted',deleted,'eventId',counter::text) ORDER BY resource_key::text),'[]') INTO page
  FROM (SELECT * FROM mcp_sync.source_records WHERE binding_id=p_binding LIMIT 100001) bounded;
  IF jsonb_array_length(page)>100000 OR octet_length(page::text)>67108864 THEN
   RAISE EXCEPTION USING ERRCODE='54000',MESSAGE='snapshot_limit_exceeded';
  END IF;
  DELETE FROM mcp_sync.source_snapshots WHERE binding_id=p_binding AND expires_at<clock_timestamp();
  INSERT INTO mcp_sync.source_snapshots(binding_id,rows,change_cursor)
  VALUES(p_binding,page,'sync:'||p_binding::text||':'||seq::text) RETURNING * INTO snapshot;
 ELSE
  IF p_cursor !~ '^snap:[0-9a-f-]+:[0-9]+$' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request'; END IF;
  SELECT * INTO snapshot FROM mcp_sync.source_snapshots
   WHERE id=split_part(p_cursor,':',2)::uuid AND binding_id=p_binding AND expires_at>clock_timestamp();
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='resnapshot_required'; END IF;
  page_offset=split_part(p_cursor,':',3)::int;
  IF page_offset>jsonb_array_length(snapshot.rows) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request'; END IF;
 END IF;
 SELECT COALESCE(jsonb_agg(value ORDER BY ordinal),'[]') INTO page
 FROM jsonb_array_elements(snapshot.rows) WITH ORDINALITY t(value,ordinal)
 WHERE ordinal>page_offset AND ordinal<=page_offset+p_limit;
 IF page_offset+jsonb_array_length(page)<jsonb_array_length(snapshot.rows) THEN
  next_cursor='snap:'||snapshot.id::text||':'||(page_offset+jsonb_array_length(page))::text;
 END IF;
 RETURN jsonb_build_object('snapshotId',snapshot.id,'rows',page,'nextCursor',next_cursor,'changeCursor',snapshot.change_cursor);
END $$;

CREATE FUNCTION mcp_sync._operation_json(o mcp_sync.outbox) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('operationId',o.operation_id,'bindingId',o.binding_id,'key',o.resource_key,
  'operation',o.operation,'precondition',o.precondition,'value',o.payload,
  'queuedLocalRevision',o.queued_local_revision,'fencingToken',o.fencing_token,
  'firstAttemptAt',o.first_attempt_at,'attempts',o.attempts,'state',o.state)
$$;

CREATE FUNCTION mcp_sync.claim_outbox(p_binding uuid,p_lease_seconds int DEFAULT 30) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE candidate mcp_sync.outbox; o mcp_sync.outbox; retention bigint;
BEGIN
 PERFORM mcp_sync._assert_worker(); PERFORM mcp_sync._assert_access(p_binding);
 PERFORM 1 FROM mcp_sync.bindings WHERE id=p_binding FOR SHARE;
 IF EXISTS(SELECT 1 FROM mcp_sync.checkpoints WHERE binding_id=p_binding AND status='paused_auth') THEN RETURN NULL; END IF;
 IF p_lease_seconds IS NULL OR p_lease_seconds<1 OR p_lease_seconds>300 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request';
 END IF;
 SELECT COALESCE((capabilities->>'idempotencyRetentionSeconds')::bigint,604800) INTO retention
  FROM mcp_sync.bindings WHERE id=p_binding;
 -- Record then queue lock order agrees with ACK, pull and conflict resolution.
 FOR candidate IN SELECT * FROM mcp_sync.outbox WHERE binding_id=p_binding
   AND ((state IN ('pending','unknown') AND next_attempt_at<=clock_timestamp())
       OR (state='claimed' AND lease_until<=clock_timestamp()))
   ORDER BY next_attempt_at,operation_id LOOP
  PERFORM 1 FROM mcp_sync.records WHERE binding_id=p_binding AND resource_key=candidate.resource_key
   FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN CONTINUE; END IF;
  SELECT * INTO o FROM mcp_sync.outbox WHERE operation_id=candidate.operation_id
   AND ((state IN ('pending','unknown') AND next_attempt_at<=clock_timestamp())
       OR (state='claimed' AND lease_until<=clock_timestamp())) FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN CONTINUE; END IF;
  IF o.first_attempt_at IS NOT NULL AND o.first_attempt_at+make_interval(secs=>retention)<=clock_timestamp() THEN
   UPDATE mcp_sync.outbox SET state='blocked',last_error='idempotency_horizon_exhausted',lease_until=NULL
    WHERE operation_id=o.operation_id;
   UPDATE mcp_sync.records SET state='blocked',local_revision=local_revision+1,last_origin='remote'
    WHERE binding_id=p_binding AND resource_key=o.resource_key;
   CONTINUE;
  END IF;
  UPDATE mcp_sync.outbox SET state='claimed',attempts=attempts+1,fencing_token=fencing_token+1,
    first_attempt_at=COALESCE(first_attempt_at,clock_timestamp()),
    lease_until=clock_timestamp()+make_interval(secs=>p_lease_seconds)
   WHERE operation_id=o.operation_id RETURNING * INTO o;
  RETURN mcp_sync._operation_json(o);
 END LOOP;
 RETURN NULL;
END $$;

CREATE FUNCTION mcp_sync._apply_clean_event(p_binding uuid,p_event jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r mcp_sync.records; seq bigint; key jsonb;
BEGIN
 key=p_event->'key'; seq=(p_event->>'eventId')::bigint;
 IF jsonb_typeof(key) IS DISTINCT FROM 'object' OR seq IS NULL OR seq<0 OR p_event->>'revision' IS NULL THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request';
 END IF;
 SELECT * INTO r FROM mcp_sync.records WHERE binding_id=p_binding AND resource_key=key FOR UPDATE;
 IF FOUND THEN
  IF r.state NOT IN ('clean','tombstone') THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='operation_pending'; END IF;
  IF r.source_counter>=seq THEN RETURN; END IF;
  UPDATE mcp_sync.records SET payload=p_event->'value',source_revision=p_event->>'revision',source_counter=seq,
   local_revision=local_revision+1,deleted=COALESCE((p_event->>'deleted')::boolean,false),
   state=CASE WHEN COALESCE((p_event->>'deleted')::boolean,false) THEN 'tombstone' ELSE 'clean' END,
   updated_at=clock_timestamp(),checked_at=clock_timestamp(),last_origin='remote'
   WHERE binding_id=p_binding AND resource_key=key;
 ELSE
  INSERT INTO mcp_sync.records(binding_id,resource_key,payload,source_revision,source_counter,local_revision,
    deleted,state,last_origin,checked_at)
  VALUES(p_binding,key,p_event->'value',p_event->>'revision',seq,1,
   COALESCE((p_event->>'deleted')::boolean,false),
   CASE WHEN COALESCE((p_event->>'deleted')::boolean,false) THEN 'tombstone' ELSE 'clean' END,'remote',clock_timestamp());
 END IF;
END $$;

CREATE FUNCTION mcp_sync._drain_deferred(p_binding uuid,p_key jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE event mcp_sync.inbound_deferred;
BEGIN
 FOR event IN SELECT * FROM mcp_sync.inbound_deferred WHERE binding_id=p_binding AND resource_key=p_key
  AND applied_at IS NULL ORDER BY event_id FOR UPDATE LOOP
  PERFORM mcp_sync._apply_clean_event(p_binding,event.event);
  UPDATE mcp_sync.inbound_deferred SET applied_at=clock_timestamp() WHERE binding_id=p_binding AND event_id=event.event_id;
 END LOOP;
END $$;

CREATE FUNCTION mcp_sync.ack_outbox(p_operation uuid,p_fence bigint,p_result jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE o mcp_sync.outbox; r mcp_sync.records; seq bigint;
BEGIN
 PERFORM mcp_sync._assert_worker();
 SELECT * INTO o FROM mcp_sync.outbox WHERE operation_id=p_operation;
 IF NOT FOUND THEN RETURN '{"applied":false}'; END IF;
 PERFORM mcp_sync._assert_access(o.binding_id);
 PERFORM 1 FROM mcp_sync.bindings WHERE id=o.binding_id FOR SHARE;
 SELECT * INTO r FROM mcp_sync.records WHERE binding_id=o.binding_id AND resource_key=o.resource_key FOR UPDATE;
 SELECT * INTO o FROM mcp_sync.outbox WHERE operation_id=p_operation FOR UPDATE;
 IF o.state NOT IN ('claimed','unknown') OR o.fencing_token<>p_fence
   OR o.queued_local_revision<>r.local_revision OR o.lease_until IS NULL OR o.lease_until<=clock_timestamp() THEN
  RETURN '{"applied":false}';
 END IF;
 IF p_result->>'operationId' IS DISTINCT FROM p_operation::text OR p_result->'key' IS DISTINCT FROM o.resource_key
   OR p_result->>'revision' IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request'; END IF;
 seq=COALESCE((p_result->>'eventId')::bigint,r.source_counter);
 UPDATE mcp_sync.outbox SET state='acknowledged',outcome=p_result,lease_until=NULL WHERE operation_id=p_operation;
 UPDATE mcp_sync.records SET payload=p_result->'value',source_revision=p_result->>'revision',
   source_counter=seq,local_revision=local_revision+1,deleted=COALESCE((p_result->>'deleted')::boolean,false),
   state=CASE WHEN COALESCE((p_result->>'deleted')::boolean,false) THEN 'tombstone' ELSE 'clean' END,
   checked_at=clock_timestamp(),updated_at=clock_timestamp(),last_origin='remote'
  WHERE binding_id=o.binding_id AND resource_key=o.resource_key;
 PERFORM mcp_sync._drain_deferred(o.binding_id,o.resource_key);
 RETURN '{"applied":true}';
END $$;

CREATE FUNCTION mcp_sync.fail_outbox(p_operation uuid,p_fence bigint,p_code text,p_evidence jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE o mcp_sync.outbox; r mcp_sync.records; conflict uuid; target text;
BEGIN
 PERFORM mcp_sync._assert_worker();
 SELECT * INTO o FROM mcp_sync.outbox WHERE operation_id=p_operation;
 IF NOT FOUND THEN RETURN '{"applied":false}'; END IF;
 PERFORM mcp_sync._assert_access(o.binding_id);
 PERFORM 1 FROM mcp_sync.bindings WHERE id=o.binding_id FOR SHARE;
 INSERT INTO mcp_sync.checkpoints(binding_id) VALUES(o.binding_id) ON CONFLICT DO NOTHING;
 PERFORM 1 FROM mcp_sync.checkpoints WHERE binding_id=o.binding_id FOR UPDATE;
 SELECT * INTO r FROM mcp_sync.records WHERE binding_id=o.binding_id AND resource_key=o.resource_key FOR UPDATE;
 SELECT * INTO o FROM mcp_sync.outbox WHERE operation_id=p_operation FOR UPDATE;
 IF o.state NOT IN ('claimed','unknown') OR o.fencing_token<>p_fence OR o.queued_local_revision<>r.local_revision
   OR o.lease_until IS NULL OR o.lease_until<=clock_timestamp() THEN RETURN '{"applied":false}'; END IF;
 IF p_code='revision_conflict' THEN
  INSERT INTO mcp_sync.conflicts(binding_id,resource_key,operation_id,base_revision,remote_revision,
    local_payload,remote_evidence,reason)
  VALUES(o.binding_id,o.resource_key,o.operation_id,o.precondition->>'revision',p_evidence->>'revision',
    r.payload,p_evidence,'revision_conflict') RETURNING id INTO conflict;
  UPDATE mcp_sync.outbox SET state='conflict',last_error=p_code,lease_until=NULL WHERE operation_id=p_operation;
  UPDATE mcp_sync.records SET state='conflict',local_revision=local_revision+1,last_origin='remote'
   WHERE binding_id=o.binding_id AND resource_key=o.resource_key;
  RETURN jsonb_build_object('applied',true,'state','conflict','conflictId',conflict);
 ELSIF p_code IN ('blocked','idempotency_mismatch','unsupported_consistency','invalid_request') THEN
  target='blocked';
  UPDATE mcp_sync.records SET state='blocked',local_revision=local_revision+1,last_origin='remote'
   WHERE binding_id=o.binding_id AND resource_key=o.resource_key;
 ELSE target='unknown'; END IF;
 UPDATE mcp_sync.outbox SET state=target,last_error=p_code,lease_until=NULL,
   next_attempt_at=clock_timestamp()+make_interval(secs=>LEAST(60,power(2,LEAST(attempts,6)))::double precision)
  WHERE operation_id=p_operation;
 IF p_code IN ('permission_denied','invalid_token','insufficient_scope') THEN
  INSERT INTO mcp_sync.checkpoints(binding_id,status) VALUES(o.binding_id,'paused_auth')
   ON CONFLICT(binding_id) DO UPDATE SET status='paused_auth';
 END IF;
 RETURN jsonb_build_object('applied',true,'state',target);
END $$;

CREATE FUNCTION mcp_sync.apply_changes(p_binding uuid,p_events jsonb,p_next_cursor text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE checkpoint mcp_sync.checkpoints; e jsonb; r mcp_sync.records; o mcp_sync.outbox;
 seq bigint; next_seq bigint; consumed bigint; applied int=0; deferred int=0;
BEGIN
 PERFORM mcp_sync._assert_worker();PERFORM mcp_sync._assert_access(p_binding);
 PERFORM 1 FROM mcp_sync.bindings WHERE id=p_binding FOR SHARE;
 IF jsonb_typeof(p_events) IS DISTINCT FROM 'array' OR jsonb_array_length(p_events)>500 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request';
 END IF;
 next_seq=mcp_sync._cache_cursor_counter(p_binding,p_next_cursor);
 INSERT INTO mcp_sync.checkpoints(binding_id) VALUES(p_binding) ON CONFLICT DO NOTHING;
 SELECT * INTO checkpoint FROM mcp_sync.checkpoints WHERE binding_id=p_binding FOR UPDATE;
 IF next_seq<checkpoint.last_event_id THEN RETURN jsonb_build_object('applied',0,'deferred',0,'stale',true); END IF;
 consumed=checkpoint.last_event_id;
 -- Lock each existing record in canonical order before processing feed order.
 PERFORM 1 FROM mcp_sync.records WHERE binding_id=p_binding
   AND resource_key IN (SELECT value->'key' FROM jsonb_array_elements(p_events))
   ORDER BY resource_key::text FOR UPDATE;
 FOR e IN SELECT value FROM jsonb_array_elements(p_events) LOOP
  seq=(e->>'eventId')::bigint;
  IF seq IS NULL OR seq>next_seq OR seq<1 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request'; END IF;
  IF seq<=consumed THEN CONTINUE; END IF;
  IF seq<>consumed+1 THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='resnapshot_required'; END IF;
  consumed=seq;
  SELECT * INTO r FROM mcp_sync.records WHERE binding_id=p_binding AND resource_key=e->'key' FOR UPDATE;
  IF FOUND AND r.state IN ('pending','conflict','blocked') THEN
   SELECT * INTO o FROM mcp_sync.outbox WHERE binding_id=p_binding AND resource_key=e->'key'
    AND state IN ('pending','claimed','unknown','conflict','blocked') FOR UPDATE;
   IF FOUND AND o.state IN ('claimed','unknown') AND o.first_attempt_at IS NOT NULL
     AND e->>'operationId'=o.operation_id::text AND o.queued_local_revision=r.local_revision THEN
    UPDATE mcp_sync.outbox SET state='acknowledged',outcome=e,lease_until=NULL WHERE operation_id=o.operation_id;
    UPDATE mcp_sync.records SET state='clean',last_origin='remote'
     WHERE binding_id=p_binding AND resource_key=r.resource_key;
    PERFORM mcp_sync._apply_clean_event(p_binding,e);
    PERFORM mcp_sync._drain_deferred(p_binding,r.resource_key);
    applied=applied+1;
   ELSE
    INSERT INTO mcp_sync.inbound_deferred(binding_id,event_id,resource_key,event)
     VALUES(p_binding,seq,e->'key',e) ON CONFLICT DO NOTHING;
    deferred=deferred+1;
   END IF;
  ELSE
   PERFORM mcp_sync._apply_clean_event(p_binding,e);applied=applied+1;
  END IF;
 END LOOP;
 IF consumed<>next_seq THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='resnapshot_required'; END IF;
 UPDATE mcp_sync.checkpoints SET source_cursor=p_next_cursor,last_event_id=next_seq,
  last_success_at=clock_timestamp(),status='ready' WHERE binding_id=p_binding;
 RETURN jsonb_build_object('applied',applied,'deferred',deferred,'nextCursor',p_next_cursor);
END $$;

CREATE FUNCTION mcp_sync.publish_snapshot(p_binding uuid,p_rows jsonb,p_cursor text,p_snapshot_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE e jsonb; seq bigint; existing_cursor bigint; count_rows int;
BEGIN
 PERFORM mcp_sync._assert_worker();PERFORM mcp_sync._assert_access(p_binding);
 PERFORM 1 FROM mcp_sync.bindings WHERE id=p_binding FOR UPDATE;
 IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows)>100000
   OR octet_length(p_rows::text)>67108864 OR p_snapshot_id IS NULL OR p_snapshot_id='' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request';
 END IF;
 seq=mcp_sync._cache_cursor_counter(p_binding,p_cursor);
 SELECT last_event_id INTO existing_cursor FROM mcp_sync.checkpoints WHERE binding_id=p_binding;
 IF COALESCE(existing_cursor,0)>seq THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='revision_conflict'; END IF;
 PERFORM 1 FROM mcp_sync.records WHERE binding_id=p_binding ORDER BY resource_key::text FOR UPDATE;
 IF EXISTS(SELECT 1 FROM mcp_sync.records WHERE binding_id=p_binding AND state IN ('pending','conflict','blocked')) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='operation_pending';
 END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows) item GROUP BY item->'key' HAVING count(*)>1) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request';
 END IF;
 FOR e IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
  IF (e->>'eventId')::bigint>seq THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request'; END IF;
  PERFORM mcp_sync._apply_clean_event(p_binding,e);
 END LOOP;
 UPDATE mcp_sync.records SET payload=NULL,deleted=true,state='tombstone',source_counter=seq,
   local_revision=local_revision+1,last_origin='remote',checked_at=clock_timestamp(),updated_at=clock_timestamp()
  WHERE binding_id=p_binding AND NOT deleted
   AND resource_key NOT IN (SELECT value->'key' FROM jsonb_array_elements(p_rows));
 INSERT INTO mcp_sync.checkpoints(binding_id,source_cursor,last_event_id,snapshot_id,last_success_at,status)
 VALUES(p_binding,p_cursor,seq,p_snapshot_id,clock_timestamp(),'ready')
 ON CONFLICT(binding_id) DO UPDATE SET source_cursor=EXCLUDED.source_cursor,last_event_id=EXCLUDED.last_event_id,
  snapshot_id=EXCLUDED.snapshot_id,last_success_at=EXCLUDED.last_success_at,status='ready';
 RETURN jsonb_build_object('published',true,'rows',jsonb_array_length(p_rows),'snapshotId',p_snapshot_id,'changeCursor',p_cursor);
END $$;

CREATE FUNCTION mcp_sync.resolve(p_conflict uuid,p_strategy text,p_expected bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE c mcp_sync.conflicts; r mcp_sync.records; o mcp_sync.outbox; latest jsonb;
 op uuid; local_value jsonb; local_deleted boolean; new_revision bigint;
BEGIN
 SELECT * INTO c FROM mcp_sync.conflicts WHERE id=p_conflict;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='permission_denied'; END IF;
 PERFORM mcp_sync._assert_access(c.binding_id,true);
 SELECT * INTO r FROM mcp_sync.records WHERE binding_id=c.binding_id AND resource_key=c.resource_key FOR UPDATE;
 SELECT * INTO o FROM mcp_sync.outbox WHERE operation_id=c.operation_id FOR UPDATE;
 SELECT * INTO c FROM mcp_sync.conflicts WHERE id=p_conflict FOR UPDATE;
 IF c.state<>'open' OR r.local_revision IS DISTINCT FROM p_expected THEN
  RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='revision_conflict';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM mcp_sync.checkpoints WHERE binding_id=c.binding_id
   AND status='ready' AND last_success_at>=c.created_at) THEN
  RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='reconciliation_required';
 END IF;
 IF p_strategy IS NULL OR p_strategy NOT IN ('accept_remote','retry_local') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='invalid_request'; END IF;
 latest=c.remote_evidence;local_value=r.payload;local_deleted=r.deleted;
 -- Prefer a newer deferred source event, retaining opaque revisions as opaque.
 SELECT event INTO latest FROM (
  SELECT c.remote_evidence AS event
  UNION ALL SELECT event FROM mcp_sync.inbound_deferred WHERE binding_id=c.binding_id
   AND resource_key=c.resource_key AND applied_at IS NULL
 ) observations ORDER BY COALESCE((event->>'eventId')::bigint,0) DESC LIMIT 1;
 IF latest->>'revision' IS NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='reconciliation_required'; END IF;
 UPDATE mcp_sync.outbox SET state='resolved' WHERE operation_id=o.operation_id;
 UPDATE mcp_sync.records SET payload=latest->'value',source_revision=latest->>'revision',
  source_counter=COALESCE((latest->>'eventId')::bigint,source_counter),local_revision=local_revision+1,
  deleted=COALESCE((latest->>'deleted')::boolean,false),last_origin='remote',
  state=CASE WHEN COALESCE((latest->>'deleted')::boolean,false) THEN 'tombstone' ELSE 'clean' END,
  checked_at=clock_timestamp(),updated_at=clock_timestamp()
 WHERE binding_id=c.binding_id AND resource_key=c.resource_key RETURNING local_revision INTO new_revision;
 UPDATE mcp_sync.inbound_deferred SET applied_at=clock_timestamp()
  WHERE binding_id=c.binding_id AND resource_key=c.resource_key AND applied_at IS NULL;
 UPDATE mcp_sync.conflicts SET state='resolved',resolution=p_strategy,resolved_at=clock_timestamp() WHERE id=p_conflict;
 IF p_strategy='retry_local' THEN
  op=gen_random_uuid();new_revision=new_revision+1;
  UPDATE mcp_sync.records SET payload=local_value,deleted=local_deleted,state='pending',
   local_revision=new_revision,last_origin='remote',updated_at=clock_timestamp()
  WHERE binding_id=c.binding_id AND resource_key=c.resource_key;
  INSERT INTO mcp_sync.outbox(operation_id,binding_id,resource_key,queued_local_revision,operation,precondition,payload,request_hash)
  VALUES(op,c.binding_id,c.resource_key,new_revision,CASE WHEN local_deleted THEN 'delete' ELSE 'update' END,
   jsonb_build_object('revision',latest->>'revision'),local_value,
   encode(sha256(convert_to(jsonb_build_object('key',c.resource_key,'value',local_value,'revision',latest->>'revision')::text,'UTF8')),'hex'));
 END IF;
 RETURN jsonb_build_object('resolved',true,'localRevision',new_revision,'operationId',op,
  'state',CASE WHEN p_strategy='retry_local' THEN 'pending' WHEN (latest->>'deleted')::boolean THEN 'tombstone' ELSE 'clean' END);
END $$;

-- Complete ownership/least-privilege setup. Application roles must never be
-- members of either owner or apply; worker logins inherit worker only.
CREATE FUNCTION mcp_sync.pause_binding(p_binding uuid,p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM mcp_sync._assert_worker();PERFORM mcp_sync._assert_access(p_binding);
 PERFORM 1 FROM mcp_sync.bindings WHERE id=p_binding FOR SHARE;
 INSERT INTO mcp_sync.checkpoints(binding_id,status) VALUES(p_binding,'paused_auth')
 ON CONFLICT(binding_id) DO UPDATE SET status='paused_auth';
 RETURN '{"paused":true,"status":"paused_auth"}';
END $$;
CREATE FUNCTION mcp_sync.resume_binding(p_binding uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM mcp_sync._assert_worker();PERFORM mcp_sync._assert_access(p_binding);
 PERFORM 1 FROM mcp_sync.bindings WHERE id=p_binding FOR SHARE;
 UPDATE mcp_sync.checkpoints SET status='ready' WHERE binding_id=p_binding AND status='paused_auth';
 UPDATE mcp_sync.outbox SET next_attempt_at=clock_timestamp() WHERE binding_id=p_binding AND state='unknown';
 RETURN '{"resumed":true}';
END $$;
DO $functions$
DECLARE f record; execution_owner text;
BEGIN
 FOR f IN SELECT p.oid,p.proname FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='mcp_sync' LOOP
  execution_owner=CASE WHEN f.proname IN ('claim_outbox','ack_outbox','fail_outbox','apply_changes',
    'publish_snapshot','resolve','_apply_clean_event','_drain_deferred','pause_binding','resume_binding') THEN 'mcp_sync_apply' ELSE 'mcp_sync_owner' END;
  EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.oid::regprocedure,execution_owner);
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',f.oid::regprocedure);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO mcp_sync_owner,mcp_sync_apply',f.oid::regprocedure);
 END LOOP;
END $functions$;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA mcp_sync TO mcp_sync_apply;
GRANT SELECT ON mcp_sync.bindings,mcp_sync.records,mcp_sync.outbox,mcp_sync.checkpoints,mcp_sync.conflicts TO mcp_sync_client,mcp_sync_worker;
GRANT INSERT(binding_id,resource_key,payload,expected_local_revision),
 UPDATE(payload,deleted,expected_local_revision) ON mcp_sync.records TO mcp_sync_client;
GRANT EXECUTE ON FUNCTION mcp_sync._can_access(uuid),mcp_sync._assert_access(uuid,boolean),
 mcp_sync.put(uuid,jsonb,jsonb,bigint),mcp_sync.remove(uuid,jsonb,bigint),mcp_sync.resolve(uuid,text,bigint)
 TO mcp_sync_client;
GRANT EXECUTE ON FUNCTION mcp_sync._can_access(uuid),mcp_sync.source_capabilities(uuid),
 mcp_sync.source_snapshot(uuid,text,int),mcp_sync.source_changes(uuid,text,int),
 mcp_sync.source_mutate(uuid,jsonb),mcp_sync.source_operation(uuid,text)
 TO mcp_sync_client,mcp_sync_worker;
GRANT EXECUTE ON FUNCTION mcp_sync.claim_outbox(uuid,int),mcp_sync.ack_outbox(uuid,bigint,jsonb),
 mcp_sync.fail_outbox(uuid,bigint,text,jsonb),mcp_sync.apply_changes(uuid,jsonb,text),
 mcp_sync.publish_snapshot(uuid,jsonb,text,text) TO mcp_sync_worker;
GRANT EXECUTE ON FUNCTION mcp_sync.pause_binding(uuid,text),mcp_sync.resume_binding(uuid) TO mcp_sync_worker;
