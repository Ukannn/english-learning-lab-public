\set ON_ERROR_STOP on
-- Disposable CI database only. The fixture, source rows and progress all roll back.
begin;
create function pg_temp.assert_true(v boolean,label text) returns void language plpgsql as $$
begin if v is not true then raise exception 'ASSERTION FAILED: %',label;end if;end $$;
create function pg_temp.expect_error(statement text,expected text) returns void language plpgsql as $$
begin
 begin execute statement;exception when others then
  if position(expected in sqlerrm)>0 then return;else raise;end if;
 end;
 raise exception 'Expected error % but succeeded',expected;
end $$;

insert into auth.users(id,email,aud,role) values
 ('a8181818-1818-4818-8818-181818181818','sense-owner@example.invalid','authenticated','authenticated'),
 ('b8181818-1818-4818-8818-181818181818','sense-outsider@example.invalid','authenticated','authenticated');
insert into english_private.app_owner(owner_id) values('a8181818-1818-4818-8818-181818181818');
select set_config('request.jwt.claim.sub','a8181818-1818-4818-8818-181818181818',true);
create temp table sense_state(k text primary key,v jsonb) on commit drop;
grant select,insert,update on sense_state to authenticated;

-- Old clients and fixtures still omit sense_key. The existing progress is meaningful.
insert into english_private.phrases(id,owner_id,chunk,cue_zh,phrase_type,review_stage,mastery_streak,next_review_at,natural_example)
values('c8181818-1818-4818-8818-181818181818',auth.uid(),'charge','收费','word',5,3,now()+interval '40 days','They charge a small fee.');
insert into english_private.phrases(owner_id,chunk,cue_zh)
values('b8181818-1818-4818-8818-181818181818','charge','控告另一义项');
insert into sense_state select 'original',to_jsonb(p) from english_private.phrases p where id='c8181818-1818-4818-8818-181818181818';
select pg_temp.assert_true(english_private.learning_sense_key(' 收费。 ')=english_private.learning_sense_key('收费')
 and english_private.learning_sense_key('收费')<>english_private.learning_sense_key('指控'),'normalized same meaning and distinct homograph senses');

insert into sense_state values('context',english_api.save_context('{"rawText":"The police may charge him.","selectedSpans":[]}',null,'sense-source-1'));
insert into sense_state values('context-job',english_api.create_ai_job('context_extract',null,(select(v->>'contextId')::uuid from sense_state where k='context'),'sense-context-job'));
insert into sense_state select 'context-frozen',jsonb_build_object('snapshot',j.input_snapshot,'hash',j.snapshot_hash) from english_private.ai_jobs j where j.id=(select(v->>'jobId')::uuid from sense_state where k='context-job');
insert into sense_state select 'context-payload',jsonb_build_object('jobId',j.id,'batchId',j.batch_id,'snapshotHash',j.snapshot_hash,'ruleVersion','english_v2','modelId','sense-test','items',jsonb_build_array(
 jsonb_build_object('contextId',j.subject_id,'position',1,'selectedText','charge','candidate','charge','cueZh','指控','candidateType','word','whyUseful','法律语境中的不同义项','naturalExample','They may charge him with theft.','confidence',0.95)))
 from english_private.ai_jobs j where j.id=(select(v->>'jobId')::uuid from sense_state where k='context-job');

-- A second occurrence paraphrases a known sense and explicitly reuses its key.
insert into sense_state values('alias-context',english_api.save_context('{"rawText":"They charge for parking.","selectedSpans":[]}',null,'sense-source-2'));
insert into sense_state values('alias-job',english_api.create_ai_job('context_extract',null,(select(v->>'contextId')::uuid from sense_state where k='alias-context'),'sense-alias-job'));
insert into sense_state select 'alias-payload',jsonb_build_object('jobId',j.id,'batchId',j.batch_id,'snapshotHash',j.snapshot_hash,'ruleVersion','english_v2','modelId','sense-test','items',jsonb_build_array(
 jsonb_build_object('contextId',j.subject_id,'position',1,'selectedText','charge','candidate','CHARGE','cueZh','收取费用','candidateType','word','whyUseful','另一来源','naturalExample','They charge for parking.','confidence',0.95,'existingSenseKey',(select v->>'sense_key' from sense_state where k='original'))))
 from english_private.ai_jobs j where j.id=(select(v->>'jobId')::uuid from sense_state where k='alias-job');

insert into sense_state values('generated-job',english_api.create_ai_job('candidate_generate',2,null,'sense-generated-job'));
insert into sense_state select 'generated-payload',jsonb_build_object('jobId',j.id,'batchId',j.batch_id,'snapshotHash',j.snapshot_hash,'ruleVersion','english_v2','modelId','sense-test','items',jsonb_build_array(
 jsonb_build_object('position',1,'candidate','charge','cueZh',' 收费。 ','candidateType','word','whyUseful','费用场景','naturalExample','Do they charge for delivery?','confidence',0.95),
 jsonb_build_object('position',2,'candidate','charge','cueZh','充电','candidateType','word','whyUseful','设备场景','naturalExample','Charge your phone before leaving.','confidence',0.95)))
 from english_private.ai_jobs j where j.id=(select(v->>'jobId')::uuid from sense_state where k='generated-job');
insert into sense_state select 'foreign-key',to_jsonb(sense_key) from english_private.phrases where owner_id='b8181818-1818-4818-8818-181818181818';

set local role authenticated;
select pg_temp.assert_true((english_api.get_ai_job_prompt((select(v->>'jobId')::uuid from sense_state where k='context-job'))->'senseInventory') @>
 jsonb_build_array(jsonb_build_object('candidate','charge','cueZh','收费','senseKey',(select v->>'sense_key' from sense_state where k='original'))),'prompt offers an owner-scoped explicit sense reference');
select pg_temp.assert_true((english_api.get_ai_job_prompt((select(v->>'jobId')::uuid from sense_state where k='context-job'))->'snapshot')=(select v->'snapshot' from sense_state where k='context-frozen'),'old frozen input is unchanged by live inventory');
select pg_temp.expect_error(format('select english_api.import_ai_result(%L,%L::jsonb)',(select v->>'jobId' from sense_state where k='alias-job'),
 (select jsonb_set(v,'{items,0,existingSenseKey}',(select v from sense_state where k='foreign-key'))::text from sense_state where k='alias-payload')),'INVALID_EXISTING_SENSE_KEY');
select pg_temp.expect_error(format('select english_api.import_ai_result(%L,%L::jsonb)',(select v->>'jobId' from sense_state where k='alias-job'),
 (select jsonb_set(v,'{items,0,candidate}','"bank"')::text from sense_state where k='alias-payload')),'INVALID_EXISTING_SENSE_KEY');
select pg_temp.expect_error(format('select english_api.import_ai_result(%L,%L::jsonb)',(select v->>'jobId' from sense_state where k='generated-job'),
 (select jsonb_set(v,'{items,1,cueZh}','"收费"')::text from sense_state where k='generated-payload')),'DUPLICATE_CANDIDATE');
select english_api.import_ai_result((select(v->>'jobId')::uuid from sense_state where k='context-job'),(select v from sense_state where k='context-payload'));
select english_api.import_ai_result((select(v->>'jobId')::uuid from sense_state where k='alias-job'),(select v from sense_state where k='alias-payload'));
select english_api.import_ai_result((select(v->>'jobId')::uuid from sense_state where k='generated-job'),(select v from sense_state where k='generated-payload'));
select pg_temp.assert_true((english_api.import_ai_result((select(v->>'jobId')::uuid from sense_state where k='context-job'),(select v from sense_state where k='context-payload'))->>'idempotent')::boolean,'keyless frozen context job retains idempotent import');
reset role;

select pg_temp.assert_true((select count(*)=1 from english_private.phrases where owner_id=auth.uid()) and not exists(select 1 from english_private.candidates),'import stages all senses without accepting them');
insert into sense_state select 'decisions',jsonb_agg(decision) from (
 select jsonb_build_object('id',id,'source','context','action','accept') decision from english_private.context_candidates where owner_id=auth.uid()
 union all select jsonb_build_object('id',id,'source','generated','action','accept') from english_private.candidate_generation_rows where owner_id=auth.uid()
) decisions;
set local role authenticated;
select english_api.confirm_candidates((select v from sense_state where k='decisions'),'sense-confirm');
select english_api.confirm_candidates((select v from sense_state where k='decisions'),'sense-confirm');
select pg_temp.expect_error('select * from english_private.phrases','permission denied');
reset role;

select pg_temp.assert_true((select count(*)=3 from english_private.candidates where owner_id=auth.uid()),'four source proposals become three senses, not four spelling copies');
select pg_temp.assert_true((select count(*)=1 from english_private.candidates where owner_id=auth.uid() and promoted_phrase_id='c8181818-1818-4818-8818-181818181818'),'both fee sources reuse the original learning item');
select pg_temp.assert_true((select c.candidate_id=g.candidate_id from english_private.context_candidates c cross join english_private.candidate_generation_rows g where c.cue_zh='收取费用' and g.cue_zh=' 收费。 '),'same-sense context and generated sources retain a shared canonical candidate link');
select pg_temp.assert_true((select to_jsonb(p)=(select v from sense_state where k='original') from english_private.phrases p where p.id='c8181818-1818-4818-8818-181818181818'),'reuse does not change any existing phrase field or progress');

-- Both active queue implementations must promote homographs independently.
insert into english_private.daily_queues(owner_id,legacy_queue_id,queue_date,planned_count,contract_version)
values(auth.uid(),'sense-v3',english_private.learning_date(),4,'english_v3'),(auth.uid(),'sense-v2',english_private.learning_date()+1,4,'english_v2');
select english_private.fill_queue_v3(auth.uid(),id) from english_private.daily_queues where legacy_queue_id='sense-v3';
select pg_temp.assert_true((select count(*)=1 from english_private.daily_queue_items i join english_private.daily_queues q on q.id=i.queue_id where q.legacy_queue_id='sense-v3' and i.selection_type='new'),'v3 preserves the one-new-sense daily cap');
select english_private.fill_queue(auth.uid(),id) from english_private.daily_queues where legacy_queue_id='sense-v2';
select pg_temp.assert_true((select count(*)=3 and count(distinct sense_key)=3 from english_private.phrases where owner_id=auth.uid() and english_private.normalize_learning_lexeme(chunk)='charge'),'fee, allegation and battery charge can all be learned');
select pg_temp.assert_true((select count(*)=2 from english_private.phrases where owner_id=auth.uid() and cue_zh in ('指控','充电') and review_stage=0),'new meanings do not inherit old progress');
select pg_temp.assert_true((select to_jsonb(p)=(select v from sense_state where k='original') from english_private.phrases p where p.id='c8181818-1818-4818-8818-181818181818') and not exists(select 1 from english_private.review_events),'promotion never resets or fabricates review evidence');
select pg_temp.assert_true(not has_function_privilege('anon','english_api.confirm_candidates(jsonb,text)','EXECUTE')
 and not has_function_privilege('authenticated','english_private.resolve_learning_sense(uuid,text,text,text)','EXECUTE')
 and not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='english_api' and p.prosecdef),'RPC wrapper and owner boundaries are unchanged');
rollback;

-- Existing ready aliases must not collide inside one v2 promotion cursor.
begin;
insert into auth.users(id,email,aud,role) values('a8181818-1818-4818-8818-181818181818','sense-owner@example.invalid','authenticated','authenticated');
insert into english_private.app_owner(owner_id) values('a8181818-1818-4818-8818-181818181818');
select set_config('request.jwt.claim.sub','a8181818-1818-4818-8818-181818181818',true);
insert into english_private.candidates(owner_id,candidate,cue_zh,status,created_at) values
 (auth.uid(),'check in','办理入住','ready',now()-interval '3 minutes'),
 (auth.uid(),'CHECK IN','办理入住。','ready',now()-interval '2 minutes'),
 (auth.uid(),'check out','办理退房','ready',now());
insert into english_private.daily_queues(owner_id,legacy_queue_id,queue_date,planned_count,contract_version)
values(auth.uid(),'sense-v2-legacy-aliases',english_private.learning_date(),2,'english_v2');
select english_private.fill_queue(auth.uid(),id) from english_private.daily_queues;
do $$ begin
 if (select count(*) from english_private.phrases)<>2
  or (select count(distinct promoted_phrase_id) from english_private.candidates where lower(candidate)='check in')<>1
  or (select count(*) from english_private.candidates where status='promoted')<>3
  or (select count(*) from english_private.daily_queue_items)<>2 then
  raise exception 'LEGACY_READY_ALIASES_DID_NOT_MERGE';
 end if;
end $$;
rollback;
