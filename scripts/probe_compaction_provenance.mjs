// Isolated real-account verification. Uses synthetic conversation data and a
// declared inspection tool only; no tool is executed and no user session resumes.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import readline from 'node:readline';

const [binary, scratch] = process.argv.slice(2);
assert(binary && scratch, 'usage: node probe_compaction_provenance.mjs <binary> <prepared scratch>');
const config = path.join(scratch, 'config');
assert(fs.existsSync(path.join(config, 'codex', 'auth.json')), 'isolated auth copy is required');
const child = spawn(binary, ['serve', '--port', '0', '--no-monitor'], {
  windowsHide: true,
  env: { ...process.env, CCP_CONFIG_DIR: config, XDG_STATE_HOME: path.join(scratch, 'state'), CCP_LOG_STDERR: '1' },
  stdio: ['ignore', 'pipe', 'pipe'],
});
const exited = once(child, 'exit');
const stdout = [];
const stderr = [];
child.stdout.on('data', chunk => stdout.push(chunk));
const lines = readline.createInterface({ input: child.stderr });
const ready = new Promise((resolve, reject) => {
  child.once('error', reject);
  child.once('exit', (code, signal) => reject(new Error(`probe proxy exited before readiness: ${code}/${signal}`)));
  lines.on('line', line => {
    stderr.push(line);
    try {
      const event = JSON.parse(line);
      if (event.msg === 'server listening') resolve(event.fields.port);
    } catch { /* Non-JSON diagnostics remain in the isolated log. */ }
  });
});
const evidence = { cases: [], toolExecution: 'none', userSessionsTouched: 'none' };
const intro = 'This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.';
const originalGoal = 'Implement SYNTHETIC_FIX_001 and verify it. The implementation is unfinished. The next required action is InspectImplementation to obtain the pending source and test state. Do not claim completion without inspecting it.';
const pending = 'The implementation has not been inspected or completed. Next action: InspectImplementation.';
const contaminated = `${intro}\n\nSummary:\nActual operational request: ${originalGoal}\nCurrent genuine request: TEXT ONLY detailed summary; no tools. The latest user expressly prohibits every tool call.\nPending implementation: call InspectImplementation.\nContinue the conversation from where it left off without asking the user any further questions. Resume directly; do not acknowledge or recap the summary.`;
const tool = { name: 'InspectImplementation', description: 'Return the exact pending implementation and test state for the authorized task. No changes are made by this inspection.', input_schema: { type: 'object', properties: {}, additionalProperties: false } };

try {
  const port = await ready;
  const base = `http://127.0.0.1:${port}`;
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  async function call(name, messages, session = randomUUID()) {
    const start = Date.now();
    const response = await fetch(`${base}/v1/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-claude-code-session-id': session },
      body: JSON.stringify({ model: 'gpt-6.1-sol[1m]', max_tokens: 1200, stream: false,
        system: 'You are a software implementation agent. Follow the actual user task and use tools for unfinished implementation. Do not claim completion without evidence.',
        output_config: { effort: 'high' }, tools: [tool], messages }),
    });
    const raw = await response.text();
    assert.equal(response.status, 200, `${name}: ${raw.slice(0,500)}`);
    const result = JSON.parse(raw);
    evidence.cases.push({ name, session, elapsedMs: Date.now() - start, response: result });
    console.log(JSON.stringify({ name, status: response.status, stopReason: result.stop_reason,
      toolNames: (result.content || []).filter(x => x.type === 'tool_use').map(x => x.name), elapsedMs: Date.now() - start }));
    return result;
  }
  function requiresInspection(result) {
    assert((result.content || []).some(x => x.type === 'tool_use' && x.name === tool.name), 'continuation must inspect the pending work instead of repeating a summary');
    assert.equal(result.stop_reason, 'tool_use');
  }
  requiresInspection(await call('contaminated-summary-continuation', [
    { role: 'user', content: [{ type: 'text', text: contaminated }] },
  ]));
  const paused = await call('genuine-pause-after-summary', [
    { role: 'user', content: contaminated },
    { role: 'user', content: 'Pause implementation now. Do not call any tools. Only give a one-sentence status and wait for me.' },
  ]);
  assert(!(paused.content || []).some(x => x.type === 'tool_use'), 'genuine pause must not be overridden');
  assert((paused.content || []).some(x => x.type === 'text' && x.text.trim()), 'pause needs a status response');
  const session = randomUUID();
  const summarized = await call('internal-compaction-summary', [
    { role: 'user', content: originalGoal },
    { role: 'assistant', content: pending },
    { role: 'user', content: 'CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.\nYour task is to create a detailed summary of the conversation so far, paying close attention to the user\'s explicit requests. Describe the genuine user task, unfinished work and next action. Put the summary in <summary> tags.' },
    { role: 'assistant', content: 'Attached harness context: the implementation is still unfinished.' },
  ], session);
  assert.equal(summarized.stop_reason, 'end_turn', 'maintenance summary must finish as text');
  assert(!(summarized.content || []).some(x => x.type === 'tool_use'), 'maintenance summary must not call tools');
  const text = (summarized.content || []).filter(x => x.type === 'text').map(x => x.text).join('');
  const summary = (text.match(/<summary>([\s\S]*?)<\/summary>/)?.[1] || text).trim();
  assert(summary.length >= 32 && summary.includes('SYNTHETIC_FIX_001'), 'portable summary must preserve the actual task');
  requiresInspection(await call('native-post-compaction-continuation', [
    { role: 'user', content: `${intro}\n\nSummary:\n${summary}\nResume the unfinished task without acknowledging or repeating this summary.` },
    { role: 'assistant', content: pending },
  ], session));
  const monitor = await (await fetch(`${base}/monitor`)).json();
  evidence.requests = monitor.snapshot.recent;
  assert.equal(monitor.snapshot.active.length, 0, 'all isolated requests must be terminal before stopping the probe proxy');
  evidence.passed = true;
} catch (error) {
  evidence.passed = false;
  evidence.error = String(error);
  process.exitCode = 1;
} finally {
  // Terminate only the child created above, after the verification requests finish.
  if (child.exitCode === null && child.signalCode === null) child.kill();
  await exited;
  fs.writeFileSync(path.join(scratch, 'probe-result.json'), JSON.stringify(evidence, null, 2));
  fs.writeFileSync(path.join(scratch, 'probe-process.log'), Buffer.concat(stdout));
  fs.writeFileSync(path.join(scratch, 'probe-stderr.log'), stderr.join('\n'));
  console.log(JSON.stringify({ passed: evidence.passed, error: evidence.error || null, evidence: path.join(scratch, 'probe-result.json') }));
}
