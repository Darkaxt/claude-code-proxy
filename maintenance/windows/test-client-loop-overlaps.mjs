import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import { excludeLoopOverlaps, reviewedLoopHashes } from './exclude-client-loop-overlaps.mjs';

const [oldRelease, newRelease, scratch] = process.argv.slice(2);
if (!oldRelease || !newRelease || !scratch) throw Error('Supply old release, new release and exact task scratch');
const root = await fs.mkdtemp(path.join(scratch, 'loop-exclusion-fixture-'));
for (const [index, release] of [oldRelease, newRelease].entries()) {
  const fixture = path.join(root, String(index)), profile = path.join(fixture, 'profile');
  await fs.mkdir(path.join(profile, 'system-prompts'), {recursive: true});
  const originals = new Map();
  for (const name of Object.keys(reviewedLoopHashes)) {
    let bytes;
    try { bytes = await fs.readFile(path.join(release, 'profile/system-prompts', name)); }
    catch (e) { if(e.code !== 'ENOENT') throw e; bytes = await fs.readFile(path.join(release, 'profile-exclusions', name)); }
    originals.set(name, bytes);
    await fs.writeFile(path.join(profile, 'system-prompts', name), bytes);
  }
  const canonical = path.join(profile, 'system-prompts/system-prompt-loop-tick-tasks.md');
  await fs.writeFile(canonical, 'Canonical variable-mapped loop remains active.');
  const changed = path.join(profile, 'system-prompts/inline-loop-tick-tasks.md');
  await fs.appendFile(changed, '\nUser edit');
  await assert.rejects(excludeLoopOverlaps(fixture, profile), /Loop overlap changed/);
  assert.deepEqual(await fs.readFile(path.join(profile, 'system-prompts/inline-loop-tick-absent.md')), originals.get('inline-loop-tick-absent.md'));
  await fs.writeFile(changed, originals.get('inline-loop-tick-tasks.md'));
  const result = await excludeLoopOverlaps(fixture, profile);
  assert.equal(result.length, 2);
  for (const [name, bytes] of originals) {
    await assert.rejects(fs.access(path.join(profile, 'system-prompts', name)), {code: 'ENOENT'});
    assert.deepEqual(await fs.readFile(path.join(fixture, 'profile-exclusions', name)), bytes);
  }
  assert.equal(await fs.readFile(canonical, 'utf8'), 'Canonical variable-mapped loop remains active.');
  assert.deepEqual(await excludeLoopOverlaps(fixture, profile), result);
}
console.log('Reviewed old/current loop pair excluded, edits rejected without partial moves, canonical named prompt retained, repeated validation passed.');
