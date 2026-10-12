-- Isolated CI fixtures only.
begin;
insert into auth.users(id,email,aud,role) values('a1111111-1111-4111-8111-111111111111','auto-context@example.invalid','authenticated','authenticated');
insert into english_private.app_owner(owner_id) values('a1111111-1111-4111-8111-111111111111');
select set_config('request.jwt.claim.sub','a1111111-1111-4111-8111-111111111111',true);
set local role authenticated;
do $$declare first jsonb; second jsonb; old_prompt jsonb;begin
 if jsonb_array_length(english_api.get_pending_ai_jobs()->'items')<>0 then raise exception 'EMPTY_JOB';end if;
 perform english_api.save_context('{"rawText":"first source","selectedSpans":[]}',null,'auto-first');
 first:=english_api.get_pending_ai_jobs();second:=english_api.get_pending_ai_jobs();
 if first<>second or jsonb_array_length(first->'items')<>1 then raise exception 'DUPLICATE_JOB';end if;
 old_prompt:=english_api.get_ai_job_prompt((first#>>'{items,0,jobId}')::uuid);
 perform english_api.save_context('{"rawText":"second source","selectedSpans":[]}',null,'auto-second');
 second:=english_api.get_pending_ai_jobs();
 if jsonb_array_length(second->'items')<>2 or english_api.get_ai_job_prompt((first#>>'{items,0,jobId}')::uuid)<>old_prompt then raise exception 'SNAPSHOT_CHANGED_OR_NEW_SOURCE_MISSING';end if;
end $$;
reset role;
do $$begin
 if exists(select 1 from english_private.contexts where status='pending') then raise exception 'UNQUEUED';end if;
 if exists(select 1 from english_private.phrases) or exists(select 1 from english_private.context_candidates) then raise exception 'AUTO_ACCEPTED';end if;
 if has_function_privilege('anon','english_api.get_pending_ai_jobs()','EXECUTE') or has_function_privilege('authenticated','english_private.run_context_queue_cron()','EXECUTE') then raise exception 'PRIVILEGE_LEAK';end if;
 if not exists(select 1 from cron.job where jobname='english-context-queue' and schedule='0 20 * * *' and active) then raise exception 'CRON_MISSING';end if;
 perform english_private.run_context_queue_cron();
 if (select count(*) from english_private.ai_jobs)<>2 then raise exception 'CRON_DUPLICATE';end if;
end $$;
rollback;
