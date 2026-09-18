import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Runtime, restoreMessages } from '../src/runtime.ts';
import { NativeFetch } from '../src/bridge.ts';

function response(delta: object, reason: string) {
  const chunk = (delta: object, finish_reason: string | null) => `data: ${JSON.stringify({ id: 'test', object: 'chat.completion.chunk', model: 'test', created: 1, choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
  return new Response(chunk(delta, null) + chunk({}, reason) + 'data: [DONE]\n\n', { headers: { 'content-type': 'text/event-stream' } });
}

test('Pi executes a tool, streams text, restores history and corrects the same record', async () => {
  const calls: Record<string, unknown>[] = [];
  let amount = 20;
  const config = { baseURL: 'https://fixture.invalid/v1', model: 'test', today: '2026-09-19', sessionID: 'test' };
  const fetch: typeof globalThis.fetch = async (_url, init) => {
    const request = JSON.parse(String(init?.body));
    const history = request.messages as { role: string }[];
    if (history.at(-1)?.role === 'tool') return response({ content: '已保存。' }, 'stop');
    const update = history.some((item) => item.role === 'tool');
    const args = update ? { id: 'record-1', amount: 30, performedOn: '2026-09-19' } : { entries: [{ activity: 'pushups', amount: 20, performedOn: '2026-09-19' }], rawText: '20个俯卧撑' };
    return response({ tool_calls: [{ index: 0, id: update ? 'update-1' : 'create-1', type: 'function', function: { name: update ? 'update_entry' : 'record_entries', arguments: JSON.stringify(args) } }] }, 'tool_calls');
  };
  const call = async (message: Record<string, unknown>) => {
    calls.push(structuredClone(message));
    if (message.type === 'tool') {
      if (message.name === 'update_entry') amount = (message.args as { amount: number }).amount;
      return { id: 'record-1', amount, status: 'saved' };
    }
    return { ok: true };
  };
  const first = new Runtime(config, [], fetch, call);
  await first.prompt('20个俯卧撑', 'request-1');
  assert.equal(calls.filter((call) => call.type === 'tool').length, 1);
  const checkpoint = JSON.parse(JSON.stringify(first.snapshot()));
  const interrupted = checkpoint.filter((message: { role: string }) => message.role !== 'toolResult').slice(0, 2);
  const repaired = restoreMessages(interrupted);
  assert.equal(repaired.at(-1)?.role, 'toolResult');
  assert.equal((repaired.at(-1) as { isError: boolean }).isError, true);
  assert.deepEqual(restoreMessages(repaired), repaired);
  assert.equal(calls.filter((call) => call.type === 'tool').length, 1);
  const second = new Runtime(config, checkpoint, fetch, call);
  await second.prompt('改成30个', 'request-2');
  assert.equal(amount, 30);
  assert.deepEqual(calls.filter((call) => call.type === 'tool').map((call) => call.operationID), ['request-1:create-1', 'request-2:update-1']);
  assert.ok(calls.some((call) => call.type === 'event' && (call.event as { type: string }).type === 'text'));
  assert.ok(calls.findIndex((call) => call.type === 'checkpoint') < calls.findIndex((call) => call.type === 'tool'));
});

test('native transport decodes fragmented UTF-8, clears completion and forwards abort', async () => {
  const calls: Record<string, unknown>[] = [];
  const native = new NativeFetch(async (message) => { calls.push(message); return { ok: true }; });
  const task = native.fetch('https://fixture.invalid/v1/chat/completions', { method: 'POST', body: '{}' });
  await new Promise((resolve) => setTimeout(resolve, 0));
  const id = calls[0].id as string;
  native.receive({ id, kind: 'head', status: 200 });
  const response = await task;
  const bytes = Buffer.from('俯卧撑30个');
  native.receive({ id, kind: 'chunk', data: bytes.subarray(0, 2).toString('base64') });
  native.receive({ id, kind: 'chunk', data: bytes.subarray(2).toString('base64') });
  native.receive({ id, kind: 'end' });
  assert.equal(await response.text(), '俯卧撑30个');
  const controller = new AbortController();
  const cancelled = native.fetch('https://fixture.invalid', { signal: controller.signal });
  await new Promise((resolve) => setTimeout(resolve, 0));
  controller.abort();
  await assert.rejects(cancelled, { name: 'AbortError' });
  assert.ok(calls.some((message) => message.type === 'fetch_cancel'));
});

test('Pi exposes deletion and forwards a real target ID to the native bridge', async () => {
  const calls: Record<string, unknown>[] = [];
  const fetch: typeof globalThis.fetch = async (_url, init) => {
    const body = JSON.parse(String(init?.body));
    assert.ok(body.tools.some((tool: { function: { name: string } }) => tool.function.name === 'delete_entry'));
    if (body.messages.at(-1)?.role === 'tool') return response({ content: '已删除。' }, 'stop');
    return response({ tool_calls: [{ index: 0, id: 'delete-1', type: 'function', function: { name: 'delete_entry', arguments: JSON.stringify({ id: 'record-1' }) } }] }, 'tool_calls');
  };
  const runtime = new Runtime({ baseURL: 'https://fixture.invalid/v1', model: 'test', today: '2026-09-19', sessionID: 'delete-test' }, [], fetch, async (message) => {
    calls.push(structuredClone(message));
    return message.type === 'tool' ? { status: 'deleted', entries: [{ id: 'record-1' }] } : { ok: true };
  });
  await runtime.prompt('删除 record-1', 'delete-request');
  const toolCalls = calls.filter((call) => call.type === 'tool');
  assert.equal(toolCalls.length, 1);
  assert.equal(toolCalls[0].name, 'delete_entry');
  assert.deepEqual(toolCalls[0].args, { id: 'record-1' });
  assert.equal(toolCalls[0].operationID, 'delete-request:delete-1');
});

test('query chart options reach native code and legacy queries remain valid', async () => {
  for (const args of [
    { from: '2026-09-13', to: '2026-09-19' },
    { from: '2026-09-13', to: '2026-09-19', activity: 'plank', presentation: 'heatmap' },
    { from: '2026-09-13', to: '2026-09-19', presentation: 'bar' },
  ]) {
    const calls: Record<string, unknown>[] = [];
    const fetch: typeof globalThis.fetch = async (_url, init) => {
      const body = JSON.parse(String(init?.body));
      assert.equal(body.tools.length, 4);
      if (body.messages.at(-1)?.role === 'tool') return response({ content: '请查看图表。' }, 'stop');
      return response({ tool_calls: [{ index: 0, id: 'query-1', type: 'function', function: { name: 'query_entries', arguments: JSON.stringify(args) } }] }, 'tool_calls');
    };
    const runtime = new Runtime({ baseURL: 'https://fixture.invalid/v1', model: 'test', today: '2026-09-19', sessionID: 'query-test' }, [], fetch, async (message) => {
      calls.push(structuredClone(message));
      return message.type === 'tool' ? { entries: [], totals: {}, visualization: { series: [] } } : { ok: true };
    });
    await runtime.prompt('查看最近一周', 'query-request');
    assert.deepEqual(calls.filter((call) => call.type === 'tool').map((call) => call.args), [args]);
  }
});
