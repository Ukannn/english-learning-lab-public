import {execFileSync} from 'node:child_process';

const repository = 'Ukannn/english-learning-lab';
const workflow = 'ci.yml';
const requiredJobs = ['check', 'database'];

export function latestProductionRun(pages, commit) {
  const runs = pages.flatMap(page => page.workflow_runs ?? [])
    .filter(run => run.head_sha === commit && run.head_branch === 'main' && run.event === 'push')
    .sort((left, right) => right.id - left.id);
  const run = runs[0];
  if (!run || run.status !== 'completed' || run.conclusion !== 'success')
    throw new Error('The latest CI workflow for this exact main commit must complete successfully before release.');
  if (!Number.isSafeInteger(run.id) || !Number.isSafeInteger(run.run_attempt) || run.run_attempt < 1)
    throw new Error('CI did not provide a verifiable workflow run and attempt.');
  return run;
}

export function assertRequiredJobs(pages, run, commit) {
  const jobs = pages.flatMap(page => page.jobs ?? []);
  for (const name of requiredJobs) {
    const job = jobs.filter(job => job.name === name && job.run_id === run.id && job.head_sha === commit)
      .sort((left, right) => right.id - left.id)[0];
    if (!job || job.status !== 'completed' || job.conclusion !== 'success')
      throw new Error(`The ${name} job in the latest CI attempt for this exact main commit must pass before release.`);
  }
}

export function assertProductionCi(root, commit, execute = execFileSync) {
  const get = endpoint => {
    const pages = JSON.parse(execute('gh', ['api', '--paginate', '--slurp', endpoint],
      {cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']}));
    if (!Array.isArray(pages)) throw new Error('Could not read paginated GitHub CI evidence.');
    return pages;
  };
  const run = latestProductionRun(get(`repos/${repository}/actions/workflows/${workflow}/runs?head_sha=${commit}&branch=main&event=push&per_page=100`), commit);
  assertRequiredJobs(get(`repos/${repository}/actions/runs/${run.id}/attempts/${run.run_attempt}/jobs?per_page=100`), run, commit);
  return {commit, runId: run.id, attempt: run.run_attempt, jobs: requiredJobs};
}
