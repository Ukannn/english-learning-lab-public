const {test} = require('node:test');
const assert = require('node:assert/strict');

test('production requires both jobs in the latest successful main workflow attempt', async () => {
  const {assertProductionCi} = await import('../../scripts/operations/ci-release-gate.mjs');
  const commit = 'a'.repeat(40);
  const run = {id: 20, run_attempt: 2, head_sha: commit, head_branch: 'main', event: 'push', status: 'completed', conclusion: 'success'};
  const job = (name, id) => ({name, id, run_id: 20, head_sha: commit, status: 'completed', conclusion: 'success'});
  const execute = (runs, jobs) => (_command, args) => JSON.stringify(args.at(-1).includes('/attempts/') ? jobs : runs);
  const runs = [{workflow_runs: [{...run, id: 10}]}, {workflow_runs: [run]}];
  const jobs = [{jobs: [job('check', 21)]}, {jobs: [job('database', 22)]}];
  const endpoints = [];
  assert.deepEqual(assertProductionCi('.', commit, (command, args) => {
    assert.equal(command, 'gh');
    assert.deepEqual(args.slice(0, 3), ['api', '--paginate', '--slurp']);
    endpoints.push(args.at(-1));
    return execute(runs, jobs)(command, args);
  }), {commit, runId: 20, attempt: 2, jobs: ['check', 'database']});
  assert.match(endpoints[1], /\/runs\/20\/attempts\/2\/jobs/);
  for (const conclusion of ['failure', 'cancelled', 'skipped', 'neutral', 'timed_out', null]) {
    assert.throws(() => assertProductionCi('.', commit, execute(runs, [{jobs: [job('check', 21), {...job('database', 22), conclusion}]}])), /database job/);
  }
  assert.throws(() => assertProductionCi('.', commit, execute(runs, [{jobs: [job('check', 21)]}])) , /database job/);
  assert.throws(() => assertProductionCi('.', commit, execute(runs, [{jobs: [job('check', 21), {...job('database', 22), status: 'in_progress'}]}])), /database job/);
  assert.throws(() => assertProductionCi('.', commit, execute(runs, [{jobs: [job('check', 21), {...job('database', 22), run_id: 10}]}])), /database job/);
  assert.throws(() => assertProductionCi('.', commit, execute(runs, [{jobs: [job('check', 21), {...job('database', 22), head_sha: 'b'.repeat(40)}]}])), /database job/);
  for (const changed of [{status: 'in_progress', conclusion: null}, {conclusion: 'failure'}, {conclusion: 'cancelled'}]) {
    assert.throws(() => assertProductionCi('.', commit, execute([{workflow_runs: [{...run, id: 10}, {...run, ...changed}]}], jobs)), /latest CI workflow/);
  }
  for (const changed of [{head_sha: 'b'.repeat(40)}, {head_branch: 'feature'}, {event: 'pull_request'}]) {
    assert.throws(() => assertProductionCi('.', commit, execute([{workflow_runs: [{...run, ...changed}]}], jobs)), /latest CI workflow/);
  }
  assert.throws(() => assertProductionCi('.', commit, execute([{workflow_runs: []}], jobs)), /latest CI workflow/);
});
