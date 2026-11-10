// A literal stock stub needs no override. Keep it out of the community template
// mapper, which interprets even literal ${ prose as interpolation in 2.9.24.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';
const digest = x => crypto.createHash('sha256').update(x).digest('hex');
const body = x => x.replace(/^<!--[^]*?-->\s*/, '').trim();
export async function excludePristineLiterals(release) {
  const m = JSON.parse(await fs.readFile(path.join(release, 'candidate.json'), 'utf8'));
  if (m.schema !== 'claudegpt.client_candidate.v1') throw Error('Invalid candidate');
  const catalog = JSON.parse(await fs.readFile(path.join(m.profile, `prompt-data-cache/v${m.tweakVersion}/prompts-${m.version}.json`), 'utf8'));
  const candidates = new Map();
  for (const p of catalog.prompts) {
    if (p.identifiers.length || !p.pieces.join('').includes('${')) continue;
    const entries = candidates.get(p.id) ?? []; entries.push(p.pieces.join('')); candidates.set(p.id, entries);
  }
  const excluded = [];
  for (const [id, originals] of candidates) {
    if (!/^[A-Za-z0-9_-]+$/.test(id)) throw Error('Unexpected catalogue ID');
    const name = `${id}.md`;
    let source;
    try { source = await fs.readFile(path.join(release, 'prompt-source/system-prompts-lcc', name), 'utf8'); }
    catch (e) { if (e.code === 'ENOENT') continue; throw e; }
    if (!originals.every(text => text.trim() === body(source))) continue;
    // Published stringifyPromptMarkdown emits the metadata plus one newline,
    // then the raw catalogue body, adding a terminal newline only if absent.
    // Accept that exact generated form or the exact community source file.
    const header = source.match(/^<!--[^]*?-->/)?.[0];
    if (!header) throw Error(`Missing stock metadata for ${id}`);
    const regenerated = originals.map(text => header + '\n' + (text.endsWith('\n') ? text : text + '\n'));
    const isStock = text => text === source || regenerated.includes(text);
    const target = path.join(m.profile, 'system-prompts', name);
    const retained = path.join(release, 'profile-exclusions/pristine-literal-stubs', name);
    let current;
    try { current = await fs.readFile(target, 'utf8'); }
    catch (e) { if (e.code !== 'ENOENT') throw e; current = await fs.readFile(retained, 'utf8'); }
    if (!isStock(current)) throw Error(`Literal stock stub ${id} has local edits; preserve and review`);
    try {
      await fs.access(target);
      await fs.mkdir(path.dirname(retained), { recursive: true });
      // Startup may regenerate a stock stub with its canonical whitespace.
      // Replace only an approved stock input; preserve/refuse any owner edit.
      try { if (!isStock(await fs.readFile(retained, 'utf8'))) throw Error(`Retained literal stub ${id} has local edits; preserve and review`); }
      catch (e) { if (e.code !== 'ENOENT') throw e; }
      await fs.rename(target, retained);
    } catch (e) { if (e.code !== 'ENOENT') throw e; }
    excluded.push({ id, sha256: digest(current), communitySha256: digest(source), retained, nativeTextUnmodified: true });
  }
  const result = { reason: 'Unmodified zero-identifier stock literals containing interpolation syntax need no override; preserve vendor text and avoid template parsing', excluded };
  await fs.writeFile(path.join(release, 'literal-profile-exclusions.json'), JSON.stringify(result, null, 2));
  return result;
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  if (!process.argv[2]) throw Error('Supply a prepared candidate release');
  console.log(JSON.stringify(await excludePristineLiterals(path.resolve(process.argv[2])), null, 2));
}
