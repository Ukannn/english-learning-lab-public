-- Prepare corpus work at 04:00 Shanghai and whenever pending AI work is read.
create or replace function english_private.enqueue_pending_contexts()
returns integer language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare o uuid:=english_private.current_owner(); c record; n integer:=0;
begin
 perform pg_advisory_xact_lock(hashtextextended(o::text,2));
 for c in select id from english_private.contexts where owner_id=o and status='pending' order by created_at,id loop
  perform english_private.create_ai_job('context_extract',null,c.id,
   'automatic-context:'||c.id::text||':'||(select count(*) from english_private.ai_jobs where owner_id=o and kind='context_extract' and subject_id=c.id)::text);
  n:=n+1;
 end loop;
 return n;
end $$;
revoke all on function english_private.enqueue_pending_contexts() from public,anon,authenticated;

create or replace function english_private.get_pending_ai_jobs()
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare o uuid:=english_private.current_owner();
begin
 perform english_private.enqueue_pending_contexts();
 return (select jsonb_build_object('ok',true,'items',coalesce(jsonb_agg(jsonb_build_object('ok',true,'jobId',id,'kind',kind,'subjectId',subject_id,'snapshotHash',snapshot_hash,'batchId',batch_id,'expectedCount',expected_count,'status',status) order by created_at,id),'[]'::jsonb))
 from english_private.ai_jobs where owner_id=o and status='prepared');
end $$;
create or replace function english_api.get_pending_ai_jobs()
returns jsonb language sql volatile security invoker set search_path=pg_catalog,pg_temp as $$
 select english_private.get_pending_ai_jobs()
$$;

create or replace function english_private.run_context_queue_cron()
returns void language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare o uuid; previous_sub text:=current_setting('request.jwt.claim.sub',true);
begin
 select owner_id into o from english_private.app_owner;
 if o is null then return;end if;
 perform set_config('request.jwt.claim.sub',o::text,true);
 perform english_private.enqueue_pending_contexts();
 perform set_config('request.jwt.claim.sub',coalesce(previous_sub,''),true);
end $$;
revoke all on function english_private.run_context_queue_cron() from public,anon,authenticated;
select cron.schedule('english-context-queue','0 20 * * *','select english_private.run_context_queue_cron()');
