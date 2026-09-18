export type BridgeCall = (message: Record<string, unknown>) => Promise<unknown>;
type Packet = { id: string; kind: 'head' | 'chunk' | 'end' | 'error'; status?: number; headers?: Record<string, string>; data?: string; error?: string };

/** Native owns credentials and networking. JS receives only response data. */
export class NativeFetch {
  private pending = new Map<string, (packet: Packet) => void>();
  private sequence = 0;
  constructor(private call: BridgeCall) {}

  receive(packet: Packet) { this.pending.get(packet.id)?.(packet); }

  fetch: typeof fetch = async (input, init) => {
    try { return await this.performFetch(input, init); }
    catch (error) {
      await this.call({ type: 'event', event: { type: 'transport_error', text: String(error) } }).catch(() => {});
      throw error;
    }
  };

  private performFetch: typeof fetch = async (input, init) => {
    const request = new Request(input, init);
    // IDs only correlate messages in this runtime; persistence IDs come from Swift.
    // about:blank WKWebView pages do not always expose secure-context randomUUID.
    const id = `fetch-${++this.sequence}`;
    const body = await request.text();
    request.signal.throwIfAborted();
    return new Promise<Response>((resolve, reject) => {
      let controller: ReadableStreamDefaultController<Uint8Array>;
      let settled = false;
      const clean = () => {
        this.pending.delete(id);
        request.signal.removeEventListener('abort', abort);
      };
      const fail = (error: Error) => {
        if (settled) return;
        settled = true;
        clean();
        reject(error);
        controller.error(error);
      };
      const abort = () => {
        fail(new DOMException('Request cancelled', 'AbortError'));
        void this.call({ type: 'fetch_cancel', id }).catch(() => {});
      };
      const responseBody = new ReadableStream<Uint8Array>({
        start: (value) => { controller = value; },
        cancel: abort,
      });
      this.pending.set(id, (packet) => {
        if (settled) return;
        if (packet.kind === 'head') {
          resolve(new Response(responseBody, { status: packet.status, headers: packet.headers }));
        } else if (packet.kind === 'chunk') {
          const raw = atob(packet.data ?? '');
          controller.enqueue(Uint8Array.from(raw, (char) => char.charCodeAt(0)));
        } else if (packet.kind === 'end') {
          settled = true;
          clean();
          controller.close();
        } else {
          fail(new Error(packet.error ?? 'Native request failed'));
        }
      });
      request.signal.addEventListener('abort', abort, { once: true });
      if (request.signal.aborted) { abort(); return; }
      // Do not send model-generated headers or credentials to the bridge.
      void this.call({ type: 'fetch_start', id, url: request.url, method: request.method, body })
        .catch((error) => fail(new Error(String(error))));
    });
  };
}
