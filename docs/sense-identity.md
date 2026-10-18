# Learning identity: spelling and sense

Each learning target has a persistent `sense_key`. New writes identify a target by owner, normalized English spelling and sense, so `charge` meaning 收费 and `charge` meaning 指控 have independent phrase IDs, review dates, stages and evidence. A different example of 收费 remains a source for the existing sense.

## Candidate contract

`cueZh` must name one clear meaning. Context extraction and generated recommendations may additionally provide `existingSenseKey`:

| Situation | Candidate output | Result after confirmation |
| --- | --- | --- |
| New meaning of an existing word | Omit `existingSenseKey`, or use `null`; supply its own `cueZh` | A new candidate and, when scheduled, a new phrase with its own progress |
| Same meaning, same normalized cue | The new field can be omitted | Reuse the existing sense and retain the new source |
| Same meaning, paraphrased cue or another example | Copy the matching key from `senseInventory` into `existingSenseKey` | Reuse the existing sense without replacing its cue, example or progress |
| An unknown key, another owner's sense or a key for another spelling | Do not submit that reference | Import fails with `INVALID_EXISTING_SENSE_KEY` |

The live `senseInventory` returned with a candidate prompt contains `candidate`, `cueZh` and `senseKey`. It is separate from the frozen snapshot. Use a key only when its spelling and meaning match the intended target; a shared spelling alone is insufficient. Keys are references supplied by the service, not model-generated labels. A single AI payload must contain each spelling/sense pair once; a repeated pair is still rejected as `DUPLICATE_CANDIDATE`. Separate source occurrences and reprocessed contexts can be imported and confirmed against the same target.

When the field is absent, the service derives `zh-v1:` followed by SHA-256 of normalized `cueZh`. Normalization lowercases text, collapses whitespace and trims whitespace and sentence punctuation at the edges. It does not infer synonyms, rewrite a meaning or use examples as identity. Explicit references are necessary when synonymous cues use different words. Spelling comparison lowercases, trims and collapses whitespace; it does not guess lemmas or merge different expressions.

For example, the new meaning can be returned as:

```json
{
  "candidate": "charge",
  "candidateType": "word",
  "cueZh": "指控",
  "existingSenseKey": null
}
```

This is the identity portion of a candidate, not a complete import envelope. Keep the job IDs, hash, positions and all existing required fields from the actual prompt. For another 收费 occurrence, copy the existing 收费 key from that prompt's inventory instead of creating a key from a paraphrase such as 收取费用.

## Persistence and compatibility

Migration `20261018081000_learning_sense_identity.sql` adds keys to phrases, confirmed candidates and both staging tables. Existing promoted/source links determine the corresponding backfilled key where available. Rows without a usable historical cue get a stable row-specific `legacy:` key so that an unknown meaning is not silently merged with another unknown meaning.

No existing phrase IDs, cues, examples, review stages, due dates or review events are replaced. The original raw-spelling uniqueness constraint is extended to include sense. A nonunique normalized lookup index preserves historical case/spacing variants that already had separate progress; future API writes serialize by owner and reuse the oldest matching sense rather than merge historical progress during migration. `confirm_candidates` retains every accepted context or generation row through its `candidate_id` link. Both v2 and v3 queue builders attach existing aliases and promote different senses without changing their daily new-item limits.

Old prepared jobs and consumed receipts remain intact. Jobs without `existingSenseKey` use the deterministic cue fallback; prompt inventories do not modify frozen snapshots or hashes. The current owner checks, invoker API wrappers, private definer implementations and authenticated grants remain the existing security boundary. Raw table access does not become available to the browser.

## Validation

`supabase/tests/008_sense_identity.sql` is a rollback-only disposable CI fixture. It covers homographs, normalized cues, explicit paraphrases, context and generated source reuse, old keyless job imports, snapshot/receipt stability, invalid references, both queue versions, legacy ready aliases and unchanged existing progress/permissions. SQL/PLpgSQL parsing is a static check; database execution must occur in the authorized disposable CI environment, not a local or production database.

Before applying the migration, these read-only counts check the existing uniqueness contract and the historical cases intentionally preserved. They return no learning text or owner identifiers:

```sql
select count(*) as phrase_rows,
       count(*) filter(where nullif(btrim(cue_zh),'') is null) as missing_cue_rows
from english_private.phrases;

select count(*) as normalized_same_meaning_groups,
       coalesce(sum(n-1),0) as additional_historical_rows
from (
  select count(*) n from english_private.phrases
  group by owner_id,
    lower(regexp_replace(btrim(chunk),'[[:space:]]+',' ','g')),
    btrim(lower(regexp_replace(btrim(coalesce(cue_zh,'')),'[[:space:]]+',' ','g')),' 。；，：！？.!?;,:')
  having count(*)>1
) existing_groups;

select conname,pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid='english_private.phrases'::regclass
  and conname='phrases_owner_id_chunk_key';
```
