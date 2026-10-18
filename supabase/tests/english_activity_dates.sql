\set ON_ERROR_STOP on
begin;
create function pg_temp.assert_true(v boolean,label text) returns void language plpgsql as $$
begin if v is not true then raise exception 'ASSERTION FAILED: %',label;end if;end $$;
create function pg_temp.expect_error(statement text,expected text) returns void language plpgsql as $$
begin begin execute statement;exception when others then
 if position(expected in sqlerrm)>0 then return;else raise exception 'Expected %, got %',expected,sqlerrm;end if;
end;raise exception 'Expected error %',expected;end $$;

-- A package older than the report window is practiced today. Its old reading
-- scalar cannot tell us when reading occurred, even though attempt dates exist.
do $$
declare o uuid:='d1111111-1111-4111-8111-111111111111';other_owner uuid:='d2222222-2222-4222-8222-222222222222';
 d date:=(now() at time zone 'Asia/Shanghai')::date;q uuid;s uuid;question uuid;
begin
 insert into auth.users(id,email,aud,role) values(o,'dates@example.invalid','authenticated','authenticated'),
  (other_owner,'other-dates@example.invalid','authenticated','authenticated');
 insert into english_private.app_owner(owner_id) values(o);
 insert into english_private.daily_queues(owner_id,legacy_queue_id,queue_date,contract_version)
 values(o,'dates-old',d-20,'english_v3') returning id into q;
 insert into english_private.sessions(id,owner_id,queue_id,learning_date,status,max_questions,contract_version,created_at)
 values('d0000000-0000-4000-8000-000000000001',o,q,d-20,'committed',3,'english_v3',now()-interval '20 days') returning id into s;
 insert into english_private.lessons(owner_id,queue_id,session_id,sequence,theme,material,active_reading_seconds,reading_started_at,reading_completed_at,created_at)
 values(o,q,s,1,'life','{"targetPhraseIds":[]}'::jsonb,90,now()-interval '20 days',now()-interval '19 days',now()-interval '20 days');
 for n in 1..3 loop
  insert into english_private.questions(owner_id,queue_id,session_id,position,question_type,content_hash,contract_version,metadata)
  values(o,q,s,n,'whole_recall','dates-question-'||n,'english_v3','{"phase":"review"}') returning id into question;
  insert into english_private.answer_drafts(owner_id,session_id,question_id,position,answer,revision,reveal_hash,answer_hash,submit_status,idempotency_key,contract_version,metadata)
  values(o,s,question,n,case when n=1 then 'answer' else '' end,1,'reveal','answer','submitted','dates-draft-'||n,'english_v3',
   jsonb_build_object('activeSeconds',case n when 1 then 120 when 2 then 30 else 60 end,
    'attemptState',case when n=1 then 'answered' else 'skipped' end,'phase','review')||
   case when n<3 then jsonb_build_object('practiceEndedAt',case when n=1 then now() else ((d-1)::timestamp at time zone 'Asia/Shanghai')+interval '12 hours' end) else '{}'::jsonb end);
 end loop;
 insert into english_private.review_events(owner_id,session_id,question_position,question_type,affects_srs,learning_date,rule_version,target_outcome,hint_used,duration_seconds,metadata)
 values(o,s,1,'whole_recall',false,d,'english_v3','correct',false,120,'{"phase":"review","exposed":false}');

 insert into english_private.daily_queues(owner_id,legacy_queue_id,queue_date,contract_version)
 values(o,'dates-reading',d-2,'english_v3') returning id into q;
 insert into english_private.sessions(id,owner_id,queue_id,learning_date,max_questions,contract_version,created_at)
 values('d0000000-0000-4000-8000-000000000002',o,q,d-2,2,'english_v3',now()-interval '2 days') returning id into s;
 insert into english_private.lessons(owner_id,queue_id,session_id,sequence,theme,material,reading_started_at,active_reading_seconds,created_at)
 values(o,q,s,2,'life','{"targetPhraseIds":[]}'::jsonb,now()-interval '2 days',45,now()-interval '2 days');

 -- Uncommitted attempts never inflate final report duration.
 insert into english_private.daily_queues(owner_id,legacy_queue_id,queue_date,contract_version)
 values(o,'dates-pending',d,'english_v3') returning id into q;
 insert into english_private.sessions(id,owner_id,queue_id,learning_date,max_questions,contract_version)
 values('d0000000-0000-4000-8000-000000000003',o,q,d,1,'english_v3') returning id into s;
 insert into english_private.questions(owner_id,queue_id,session_id,position,content_hash,contract_version)
 values(o,q,s,1,'pending','english_v3') returning id into question;
 insert into english_private.answer_drafts(owner_id,session_id,question_id,position,answer,revision,reveal_hash,answer_hash,idempotency_key,contract_version,metadata)
 values(o,s,question,1,'not committed',1,'pending','pending','pending','english_v3',jsonb_build_object('activeSeconds',600,'practiceEndedAt',now()));

 insert into english_private.daily_queues(owner_id,legacy_queue_id,queue_date,contract_version)
 values(other_owner,'dates-other',d,'english_v3') returning id into q;
 insert into english_private.sessions(id,owner_id,queue_id,learning_date,max_questions,contract_version)
 values('d0000000-0000-4000-8000-000000000004',other_owner,q,d,1,'english_v3') returning id into s;
 insert into english_private.lessons(owner_id,queue_id,session_id,sequence,theme,material,active_reading_seconds)
 values(other_owner,q,s,1,'life','{"targetPhraseIds":[]}'::jsonb,700);
end $$;

select set_config('request.jwt.claim.sub','d1111111-1111-4111-8111-111111111111',true);
set local role authenticated;
do $$
declare d date:=(now() at time zone 'Asia/Shanghai')::date;r jsonb;s uuid:='d0000000-0000-4000-8000-000000000002';dates jsonb;
begin
 r:=english_api.get_dashboard();
 perform pg_temp.assert_true((select (x->>'durationMinutes')::numeric=3 from jsonb_array_elements(r->'v3'->'days')x where x->>'date'=d::text),
  'a twenty-day-old package reports today attempts and fallback timestamps today, excluding uncommitted work');
 perform pg_temp.assert_true((select (x->>'durationMinutes')::numeric=.5 from jsonb_array_elements(r->'v3'->'days')x where x->>'date'=(d-1)::text),
  'a skipped attempt keeps its actual frozen date without a review event');
 perform pg_temp.assert_true((r->'v3'->>'unallocatedReadingSeconds')::integer=90,'historical reading remains undated and owner scoped');
 perform pg_temp.assert_true((select (x->>'attempts')::integer=1 from jsonb_array_elements(r->'v3'->'days')x where x->>'date'=d::text),
  'time repair does not turn skips into retrieval attempts');

 perform english_api.record_lesson_activity(s,'reading_time',45,null,'old-client-reading');
 dates:=jsonb_build_object(d::text,30);
 r:=english_api.record_lesson_activity_with_dates(s,'reading_time',75,null,'dated-reading',dates);
 perform pg_temp.assert_true(r=english_api.record_lesson_activity_with_dates(s,'reading_time',75,null,'dated-reading',dates),'same payload retry is idempotent');
 perform pg_temp.expect_error(format('select english_api.record_lesson_activity_with_dates(%L,%L,76,null,%L,%L::jsonb)',s,'reading_time','dated-reading',dates),'IDEMPOTENCY_CONFLICT');
 dates:=jsonb_build_object((d-1)::text,15,d::text,30);
 perform english_api.record_lesson_activity_with_dates(s,'reading_time',90,null,'other-device-date',dates);
 perform english_api.record_lesson_activity_with_dates(s,'reading_time',60,null,'stale-device',jsonb_build_object(d::text,15));
 r:=english_api.get_review_bootstrap();
 perform pg_temp.assert_true((r->'lesson'->>'readingSeconds')::integer=90 and r->'lesson'->'readingSecondsByDate'=dates,
  'recovery keeps day maxima, retains the undated baseline and exposes both fields');
 perform english_api.record_lesson_activity(s,'reading_time',100,null,'old-client-after-dates');
 dates:=jsonb_build_object((d-1)::text,15,d::text,40);
 perform english_api.record_lesson_activity_with_dates(s,'reading_complete',110,null,'finish-reading',dates);
 r:=english_api.get_review_bootstrap();
 perform pg_temp.assert_true((r->'lesson'->>'readingSeconds')::integer=110 and r->'lesson'->'readingSecondsByDate'=dates,
  'old clients remain compatible without assigning their extra undated reading to today');

 perform pg_temp.expect_error(format('select english_api.record_lesson_activity_with_dates(%L,%L,110,null,%L,%L::jsonb)',s,'reading_time','future-date',jsonb_build_object((d+1)::text,1)),'INVALID_READING_DATES');
 perform pg_temp.expect_error(format('select english_api.record_lesson_activity_with_dates(%L,%L,110,null,%L,%L::jsonb)',s,'reading_time','before-lesson',jsonb_build_object((d-3)::text,1)),'INVALID_READING_DATES');
 perform pg_temp.expect_error(format('select english_api.record_lesson_activity_with_dates(%L,%L,110,null,%L,%L::jsonb)',s,'reading_time','negative-time',jsonb_build_object(d::text,-1)),'INVALID_READING_DATES');
 perform pg_temp.expect_error(format('select english_api.record_lesson_activity_with_dates(%L,%L,1,null,%L,%L::jsonb)',s,'reading_time','excess-total',jsonb_build_object(d::text,2)),'INVALID_READING_DATES');
 perform pg_temp.expect_error('select english_api.record_lesson_activity_with_dates(''d0000000-0000-4000-8000-000000000004'',''reading_time'',1,null,''other-owner'',''{}'')','LESSON_NOT_FOUND');
end $$;
reset role;

-- Only fixture status changes here; production migration changes no historical events.
update english_private.sessions set status='committed' where id='d0000000-0000-4000-8000-000000000002';
set local role authenticated;
do $$
declare r jsonb:=english_api.get_dashboard();d date:=(now() at time zone 'Asia/Shanghai')::date;
begin
 perform pg_temp.assert_true((select (x->>'durationMinutes')::numeric=3.7 from jsonb_array_elements(r->'v3'->'days')x where x->>'date'=d::text),
  'today adds 40 actual reading seconds to 180 answer seconds');
 perform pg_temp.assert_true((select (x->>'durationMinutes')::numeric=.8 from jsonb_array_elements(r->'v3'->'days')x where x->>'date'=(d-1)::text),
  'yesterday adds its own 15 reading seconds to its 30 answer seconds');
 perform pg_temp.assert_true((r->'v3'->>'unallocatedReadingSeconds')::integer=145,'both old reading baselines are preserved separately');
 perform pg_temp.assert_true((select x->>'durationMinutes' is null from jsonb_array_elements(r->'v3'->'days')x where x->>'date'=(d-2)::text),
  'package creation date receives no fabricated reading time');
end $$;
reset role;
-- Reset only this disposable fixture to the legacy-local/cloud counterexample.
update english_private.sessions set status='open' where id='d0000000-0000-4000-8000-000000000002';
update english_private.lessons set active_reading_seconds=95,
 reading_seconds_by_date=jsonb_build_object(((now() at time zone 'Asia/Shanghai')::date-1)::text,20)
 where session_id='d0000000-0000-4000-8000-000000000002';
set local role authenticated;
do $$
declare d date:=(now() at time zone 'Asia/Shanghai')::date;s uuid:='d0000000-0000-4000-8000-000000000002';r jsonb;dates jsonb;
begin
 dates:=jsonb_build_object((d-1)::text,20,d::text,10);
 perform english_api.record_lesson_activity_with_dates(s,'reading_time',105,null,'unsynced-legacy-baseline',jsonb_build_object(d::text,10));
 r:=english_api.get_review_bootstrap();
 perform pg_temp.assert_true((r->'lesson'->>'readingSeconds')::integer=125 and r->'lesson'->'readingSecondsByDate'=dates,
  'cloud 95 minus dated 20 and local 105 minus dated 10 preserve the larger undated 95 plus both dates');
 perform english_api.record_lesson_activity_with_dates(s,'reading_time',105,null,'unsynced-legacy-baseline',jsonb_build_object(d::text,10));
 perform english_api.record_lesson_activity_with_dates(s,'reading_time',95,null,'old-cloud-replay',jsonb_build_object((d-1)::text,20));
 r:=english_api.get_review_bootstrap();
 perform pg_temp.assert_true((r->'lesson'->>'readingSeconds')::integer=125 and r->'lesson'->'readingSecondsByDate'=dates,
  'exact retries and replay of the smaller old baseline neither double-count nor reduce merged evidence');
end $$;
reset role;
update english_private.lessons set active_reading_seconds=6000,
 reading_seconds_by_date=jsonb_build_object(((now() at time zone 'Asia/Shanghai')::date-1)::text,6000)
 where session_id='d0000000-0000-4000-8000-000000000002';
set local role authenticated;
do $$
declare d date:=(now() at time zone 'Asia/Shanghai')::date;s uuid:='d0000000-0000-4000-8000-000000000002';r jsonb;dates jsonb;
begin
 dates:=jsonb_build_object((d-1)::text,6000,d::text,1200);
 perform english_api.record_lesson_activity_with_dates(s,'reading_complete',6000,null,'two-offline-days',jsonb_build_object(d::text,6000));
 r:=english_api.get_review_bootstrap();
 perform pg_temp.assert_true((r->'lesson'->>'readingSeconds')::integer=7200 and r->'lesson'->'readingSecondsByDate'=dates
  and (r->'lesson'->>'readingCompleted')::boolean,'two offline 6000-second days share the original budget and reading_complete succeeds');
 perform english_api.record_lesson_activity_with_dates(s,'reading_time',7200,null,'finish-at-cap',dates);
 perform english_api.record_lesson_activity_with_dates(s,'reading_time',6000,null,'replay-later-day-at-cap',jsonb_build_object(d::text,6000));
 r:=english_api.get_review_bootstrap();
 perform pg_temp.assert_true((r->'lesson'->>'readingSeconds')::integer=7200 and r->'lesson'->'readingSecondsByDate'=dates,
  'finish synchronization and old-device replay retain the same bounded actual dates');
end $$;
reset role;
update english_private.lessons set active_reading_seconds=7100,
 reading_seconds_by_date=jsonb_build_object(((now() at time zone 'Asia/Shanghai')::date-1)::text,100)
 where session_id='d0000000-0000-4000-8000-000000000002';
set local role authenticated;
do $$
declare d date:=(now() at time zone 'Asia/Shanghai')::date;s uuid:='d0000000-0000-4000-8000-000000000002';r jsonb;dates jsonb;
begin
 dates:=jsonb_build_object((d-1)::text,100,d::text,100);
 perform english_api.record_lesson_activity_with_dates(s,'reading_complete',6000,null,'cap-with-undated',jsonb_build_object(d::text,6000));
 r:=english_api.get_review_bootstrap();
 perform pg_temp.assert_true((r->'lesson'->>'readingSeconds')::integer=7200 and r->'lesson'->'readingSecondsByDate'=dates,
  '7000 undated seconds leave 200 for their actual dates, without preventing reading completion');
 perform english_api.record_lesson_activity_with_dates(s,'reading_complete',7200,null,'entire-budget-undated','{}'::jsonb);
 r:=english_api.get_review_bootstrap();
 perform pg_temp.assert_true((r->'lesson'->>'readingSeconds')::integer=7200 and r->'lesson'->'readingSecondsByDate'='{}'::jsonb,
  'a full legacy undated budget stays undated and does not prevent reading completion');
end $$;
select pg_temp.assert_true(not (select prosecdef from pg_proc where oid='english_api.record_lesson_activity_with_dates(uuid,text,integer,text,text,jsonb)'::regprocedure),'public wrapper stays invoker');
select pg_temp.assert_true((select prosecdef from pg_proc where oid='english_private.record_lesson_activity_with_dates(uuid,text,integer,text,text,jsonb)'::regprocedure),'owner-checked implementation stays private definer');
select pg_temp.assert_true(not has_function_privilege('anon','english_api.record_lesson_activity_with_dates(uuid,text,integer,text,text,jsonb)','EXECUTE'),'anonymous callers cannot write reading evidence');
select set_config('request.jwt.claim.sub','d2222222-2222-4222-8222-222222222222',true);
select pg_temp.expect_error('select english_api.record_lesson_activity_with_dates(''d0000000-0000-4000-8000-000000000002'',''reading_time'',1,null,''not-owner'',''{}'')','OWNER_REQUIRED');
reset role;
rollback;
