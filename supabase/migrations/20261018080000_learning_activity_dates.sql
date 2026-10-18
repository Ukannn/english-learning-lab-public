begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

-- Legacy reading totals do not prove which dates contained active reading.
-- Add dated evidence without moving those totals, grades, or SRS history.
alter table english_private.lessons
 add column reading_seconds_by_date jsonb not null default '{}'::jsonb
 check (jsonb_typeof(reading_seconds_by_date) = 'object');

create function english_private.record_lesson_activity_with_dates(
 p_session_id uuid, p_action text, p_seconds integer, p_burden text,
 p_idempotency_key text, p_reading_seconds_by_date jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare
 o uuid:=english_private.current_owner(); l english_private.lessons%rowtype;
 h text; r jsonb; entry record; day date; dated_total integer; unallocated integer;
 merged jsonb; bounded jsonb:='{}'::jsonb; remaining integer; kept integer; total integer;
begin
 perform pg_advisory_xact_lock(hashtextextended(o::text,2));
 h:=english_private.sha256_json(jsonb_build_array(p_session_id,p_action,p_seconds,p_burden,p_reading_seconds_by_date));
 select response into r from english_private.rpc_idempotency
 where owner_id=o and operation='lesson_activity_dates' and idempotency_key=p_idempotency_key and request_hash=h;
 if r is not null then return r;end if;
 if nullif(p_idempotency_key,'') is null or exists(select 1 from english_private.rpc_idempotency
  where owner_id=o and operation='lesson_activity_dates' and idempotency_key=p_idempotency_key) then
  raise exception 'IDEMPOTENCY_CONFLICT';
 end if;
 select * into l from english_private.lessons where session_id=p_session_id and owner_id=o for update;
 if l.id is null then raise exception 'LESSON_NOT_FOUND';end if;
 if p_action is null or p_action not in ('reading_start','reading_complete','reading_time')
  or p_seconds is null or p_seconds not between 0 and 7200 then raise exception 'INVALID_LESSON_ACTIVITY';end if;
 if jsonb_typeof(p_reading_seconds_by_date) is distinct from 'object'
  or octet_length(p_reading_seconds_by_date::text)>65536 then raise exception 'INVALID_READING_DATES';end if;
 dated_total:=0;
 for entry in select key,value from jsonb_each(p_reading_seconds_by_date) loop
  if entry.key !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or jsonb_typeof(entry.value) is distinct from 'number'
   or entry.value::text !~ '^[0-9]{1,4}$' then raise exception 'INVALID_READING_DATES';end if;
  begin day:=entry.key::date;exception when datetime_field_overflow or invalid_datetime_format then
   raise exception 'INVALID_READING_DATES';end;
  if day<english_private.learning_date(l.created_at) or day>english_private.learning_date()
   or (entry.value::text)::integer>7200 then raise exception 'INVALID_READING_DATES';end if;
  dated_total:=dated_total+(entry.value::text)::integer;
 end loop;
 if dated_total>p_seconds then raise exception 'INVALID_READING_DATES';end if;

 -- Per-date cumulative maxima make retries and device recovery idempotent.
 select coalesce(jsonb_object_agg(key,seconds),'{}'::jsonb) into merged
 from (select key,max(value::integer) seconds from (
  select key,value from jsonb_each_text(l.reading_seconds_by_date)
  union all select key,value from jsonb_each_text(p_reading_seconds_by_date)
 ) values_by_date group by key) maxima;
 -- A pre-migration local scalar may contain more undated reading than the cloud.
 -- Preserve the larger baseline from either side, matching mergeReadingTime.
 select greatest(0,l.active_reading_seconds-coalesce(sum(value::integer),0),p_seconds-dated_total) into unallocated
 from jsonb_each_text(l.reading_seconds_by_date);
 -- Match normalizeReadingTime: preserve undated history first, then retain the
 -- earliest actual dated seconds within the existing two-hour lesson budget.
 -- Overflow is excluded from recorded duration, never moved to another date.
 unallocated:=least(7200,unallocated);
 remaining:=7200-unallocated;
 for entry in select key,value::integer seconds from jsonb_each_text(merged) order by key collate "C" loop
  kept:=least(entry.seconds,remaining);
  if kept>0 then bounded:=jsonb_set(bounded,array[entry.key],to_jsonb(kept),true);end if;
  remaining:=remaining-kept;
 end loop;
 merged:=bounded;
 total:=7200-remaining;

 -- Preserve the existing phase, owner, session-state and exposure validation.
 r:=english_private.record_lesson_activity(p_session_id,p_action,p_seconds,p_burden,'dated:'||p_idempotency_key);
 update english_private.lessons set reading_seconds_by_date=merged,active_reading_seconds=total where id=l.id;
 insert into english_private.rpc_idempotency(owner_id,operation,idempotency_key,request_hash,response)
 values(o,'lesson_activity_dates',p_idempotency_key,h,r);
 return r;
end $$;

create function english_api.record_lesson_activity_with_dates(
 p_session_id uuid, p_action text, p_seconds integer, p_burden text,
 p_idempotency_key text, p_reading_seconds_by_date jsonb
) returns jsonb language sql security invoker set search_path=pg_catalog,pg_temp as $$
 select english_private.record_lesson_activity_with_dates(p_session_id,p_action,p_seconds,p_burden,p_idempotency_key,p_reading_seconds_by_date)
$$;
revoke all on function english_private.record_lesson_activity_with_dates(uuid,text,integer,text,text,jsonb) from public,anon,authenticated;
revoke all on function english_api.record_lesson_activity_with_dates(uuid,text,integer,text,text,jsonb) from public,anon,authenticated;
grant execute on function english_private.record_lesson_activity_with_dates(uuid,text,integer,text,text,jsonb) to authenticated;
grant execute on function english_api.record_lesson_activity_with_dates(uuid,text,integer,text,text,jsonb) to authenticated;


-- Expose the new evidence while retaining all frozen bootstrap fields.
create or replace function english_private.get_review_bootstrap() returns jsonb language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare o uuid:=english_private.current_owner();d date:=english_private.learning_date();q uuid;ss english_private.sessions%rowtype;l english_private.lessons%rowtype;items jsonb;n integer;cfg jsonb;
begin
 perform pg_advisory_xact_lock(hashtextextended(o::text,2));
 if exists(select 1 from english_private.sessions where owner_id=o and contract_version='english_v2' and (status in ('open','submitted','grading','needs_confirmation') or learning_date=d)) or exists(select 1 from english_private.ai_jobs j join english_private.daily_queues dq on dq.id=j.subject_id where j.owner_id=o and j.kind='question_prepare' and j.status='prepared' and dq.contract_version='english_v2') or (not (english_private.rule_v3(o)->>'enabled')::boolean and not exists(select 1 from english_private.sessions where owner_id=o and contract_version='english_v3' and status in ('open','submitted','grading','needs_confirmation')) and not exists(select 1 from english_private.ai_jobs where owner_id=o and status='prepared' and input_snapshot->>'ruleVersion'='english_v3')) then
  return english_private.get_review_bootstrap_v2();
 end if;
 select * into ss from english_private.sessions where owner_id=o and contract_version='english_v3' and status in ('open','submitted','grading','needs_confirmation') order by created_at limit 1;
 if ss.id is not null then q:=ss.queue_id;else select subject_id into q from english_private.ai_jobs where owner_id=o and kind='question_prepare' and status='prepared' and input_snapshot->>'ruleVersion'='english_v3' order by created_at limit 1;
 if q is null then q:=english_private.queue_for_day_v3(o,d);end if;select * into ss from english_private.sessions where queue_id=q;end if;
 select * into l from english_private.lessons where queue_id=q;
 select count(*) into n from english_private.daily_queue_items where queue_id=q;
 cfg:=english_private.rule_v3(o);
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'position',x.position,'phraseId',x.phrase_id,'candidateId',x.candidate_id,'questionType',x.question_type,'promptZh',x.prompt_zh,'promptEn',x.prompt_en,'expectedAnswers',x.expected_answers,'acceptedVariants',x.accepted_variants,'semanticBoundary',null,'contentHash',x.content_hash,'ruleVersion','english_v3')||x.metadata||jsonb_build_object('hintCount',coalesce(a.hint_count,0),'learningCardViewed',coalesce(a.study_viewed,false),'draft',case when dr.id is null then null else jsonb_build_object('answer',dr.answer,'revision',dr.revision,'answerHash',dr.answer_hash,'status',dr.submit_status)||dr.metadata end) order by x.position),'[]'::jsonb) into items
 from english_private.questions x left join english_private.answer_drafts dr on dr.question_id=x.id left join english_private.question_activity a on a.question_id=x.id where x.queue_id=q;
 return jsonb_build_object('ok',true,'ruleVersion','english_v3','state',case when l.id is not null then ss.status when n>0 or exists(select 1 from english_private.phrases ph where owner_id=o and status in ('active','mastered') and (status='mastered' or exists(select 1 from english_private.review_events e where e.phrase_id=ph.id))) then 'questions_required' else 'empty' end,
 'learningDate',coalesce(ss.learning_date,d),'queueId',q,'actualCount',n,'settings',jsonb_build_object('defaultQuestionCount',cfg->'reviewCount','todayQuestionCount',n,'minimumTodayCount',4,'revision',cfg->'revision','ruleVersion','english_v3'),
 'session',case when ss.id is null then null else jsonb_build_object('id',ss.id,'revision',ss.revision,'maxQuestions',ss.max_questions,'status',ss.status,'submissionId',(select id from english_private.submissions where session_id=ss.id)) end,'questions',items,
 'lesson',case when l.id is null then null else jsonb_build_object('id',l.id,'theme',l.theme,'sequence',l.sequence,'material',case when l.reading_started_at is null then null else l.material end,'readingStarted',l.reading_started_at is not null,'readingCompleted',l.reading_completed_at is not null,'readingSeconds',l.active_reading_seconds,'readingSecondsByDate',l.reading_seconds_by_date,'burden',l.burden) end);
end $$;

-- Keep existing event denominators; only change time attribution.
create or replace function english_private.get_dashboard() returns jsonb language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare o uuid:=english_private.current_owner();r jsonb;v jsonb;d date:=english_private.learning_date();backlog integer;
begin
 r:=english_private.get_dashboard_v2();
 select count(*) into backlog from english_private.phrases where owner_id=o and status in ('active','mastered') and next_review_at<((d+1)::timestamp at time zone 'Asia/Shanghai');
 with activity_time as (
  -- A frozen attempt uses its committed practice date. Skips have no review
  -- event, so use the same frozen timestamp fallback as commit_submission.
  select coalesce(e.learning_date,english_private.learning_date(coalesce(
   nullif(ad.metadata->>'practiceEndedAt','')::timestamptz,a.revealed_at,ad.created_at))) learning_day,
   coalesce((ad.metadata->>'activeSeconds')::integer,0) seconds
  from english_private.answer_drafts ad join english_private.sessions s on s.id=ad.session_id
  left join english_private.question_activity a on a.question_id=ad.question_id
  left join lateral (select ev.learning_date from english_private.review_events ev
   where ev.owner_id=o and ev.question_position=ad.position and ev.session_id=s.id and ev.rule_version='english_v3'
   order by ev.reviewed_at,ev.id limit 1) e on true
  where s.owner_id=o and s.contract_version='english_v3' and s.status='committed'
  union all
  select reading.key::date,reading.value::integer
  from english_private.lessons l join english_private.sessions s on s.id=l.session_id
  cross join lateral jsonb_each_text(l.reading_seconds_by_date) reading
  where l.owner_id=o and s.owner_id=o and s.contract_version='english_v3' and s.status='committed'
 ), days as(select generate_series(d-13,d,interval '1 day')::date learning_day), data as (
 select days.learning_day,
 count(e.id) filter(where e.metadata->>'phase'='review' and e.question_type not in ('collocation_gap','contextual_gap') and not e.initial_learning and not coalesce((e.metadata->>'exposed')::boolean,false) and e.target_outcome<>'not_measured') independent_attempts,
 count(e.id) filter(where e.metadata->>'phase'='review' and e.question_type not in ('collocation_gap','contextual_gap') and not e.initial_learning and not coalesce((e.metadata->>'exposed')::boolean,false) and not e.hint_used and e.target_outcome='correct') independent_success,
 count(e.id) filter(where e.hint_used) hinted,
 count(e.id) attempts,
 count(e.id) filter(where e.question_type='collocation_gap') gap_attempts,
 count(e.id) filter(where e.question_type='collocation_gap' and e.target_outcome='correct') gap_success,
 count(e.id) filter(where e.metadata->>'phase'='expression') expression_attempts,
 count(e.id) filter(where e.metadata->>'phase'='expression' and e.meaning_ok and e.naturalness<>'major_issue') expression_success,
 count(e.id) filter(where e.target_outcome='not_measured') unmeasured,
 count(e.id) filter(where e.metadata->>'phase'='review' and not e.initial_learning and not coalesce((e.metadata->>'exposed')::boolean,false) and e.question_type not in ('collocation_gap','contextual_gap') and e.target_outcome<>'not_measured' and exists(select 1 from english_private.lesson_exposures ex where ex.owner_id=o and ex.phrase_id=e.phrase_id and ex.source='reading' and ex.learning_date<e.learning_date)) delayed_attempts,
 count(e.id) filter(where e.metadata->>'phase'='review' and not e.initial_learning and not coalesce((e.metadata->>'exposed')::boolean,false) and e.question_type not in ('collocation_gap','contextual_gap') and e.target_outcome='correct' and not e.hint_used and exists(select 1 from english_private.lesson_exposures ex where ex.owner_id=o and ex.phrase_id=e.phrase_id and ex.source='reading' and ex.learning_date<e.learning_date)) delayed_success
 from days left join english_private.review_events e on e.owner_id=o and e.rule_version='english_v3' and e.learning_date=days.learning_day group by days.learning_day)
 select jsonb_build_object('completedLessons',(select count(*) from english_private.lessons l join english_private.sessions s on s.id=l.session_id where l.owner_id=o and s.status='committed' and l.reading_completed_at is not null and (select count(*) from english_private.review_events e where e.session_id=s.id and e.metadata->>'phase'='expression')=2),
 'unallocatedReadingSeconds',(select coalesce(sum(greatest(0,l.active_reading_seconds-
  (select coalesce(sum(value::integer),0) from jsonb_each_text(l.reading_seconds_by_date)))),0)
  from english_private.lessons l join english_private.sessions s on s.id=l.session_id
  where l.owner_id=o and s.owner_id=o and s.contract_version='english_v3' and s.status='committed'),
 'dueCount',backlog,'days',jsonb_agg(jsonb_build_object('date',learning_day,'independentAttempts',independent_attempts,'independentSuccess',independent_success,'hinted',hinted,'attempts',attempts,'gapAttempts',gap_attempts,'gapSuccess',gap_success,'expressionAttempts',expression_attempts,'expressionSuccess',expression_success,'unmeasured',unmeasured,'delayedAttempts',delayed_attempts,'delayedSuccess',delayed_success,
 'durationMinutes',(select round(sum(t.seconds)/60.0,1) from activity_time t where t.learning_day=data.learning_day)) order by learning_day),
 'burden',(select coalesce(jsonb_agg(jsonb_build_object('date',s.learning_date,'value',l.burden)),'[]'::jsonb) from english_private.lessons l join english_private.sessions s on s.id=l.session_id where l.owner_id=o and l.burden is not null and s.learning_date>=d-13)) into v from data;
 r:=r||jsonb_build_object('v3',v);
 r:=jsonb_set(r,'{analytics,legacyReviews}',to_jsonb((select count(*) from english_private.review_events where owner_id=o and rule_version is distinct from 'english_v2' and rule_version is distinct from 'english_v3')));
 if exists(select 1 from english_private.daily_queues where owner_id=o and queue_date=d and contract_version='english_v3') then
 r:=jsonb_set(r,'{today}',jsonb_build_object('planned',(select count(*) from english_private.questions q join english_private.daily_queues dq on dq.id=q.queue_id where dq.owner_id=o and dq.queue_date=d and dq.contract_version='english_v3'),
 'completed',(select count(*) from english_private.review_events where owner_id=o and learning_date=d and rule_version='english_v3'),
 'waitingForGrading',(select count(*) from english_private.submissions su join english_private.sessions s on s.id=su.session_id where su.owner_id=o and s.contract_version='english_v3' and su.status in ('submitted','grading','needs_confirmation'))));end if;
 return r;
end $$;

notify pgrst,'reload schema';
commit;
