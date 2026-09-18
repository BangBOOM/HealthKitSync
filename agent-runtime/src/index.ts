import { NativeFetch, type BridgeCall } from './bridge';
import { Runtime, type Configuration } from './runtime';
import type { AgentMessage } from '@earendil-works/pi-agent-core';

declare global {
  interface Window { webkit: { messageHandlers: { pi: { postMessage(message: string): Promise<string> } } } }
}
const call: BridgeCall = async (message) => JSON.parse(await window.webkit.messageHandlers.pi.postMessage(JSON.stringify(message)));
const transport = new NativeFetch(call);
let runtime: Runtime | undefined;
Object.assign(globalThis, { PiRuntime: {
  initialize(config: Configuration, messages: AgentMessage[] = []) {
    runtime?.abort();
    runtime = new Runtime(config, messages, transport.fetch, call);
    return true;
  },
  prompt: (text: string, id: string) => runtime!.prompt(text, id),
  abort: () => runtime?.abort(),
  snapshot: () => runtime?.snapshot() ?? [],
  receive: (packet: Parameters<NativeFetch['receive']>[0]) => transport.receive(packet),
} });
void call({ type: 'ready', version: '0.85.1' });
