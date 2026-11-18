import { it, expect, vi, afterEach } from "vitest";
import { NativeClient } from "../native/client";
import { envelope } from "../shared/protocol";
function event() {
  const handlers: ((...args: unknown[]) => void)[] = [];
  return {
    addListener: (fn: (...args: unknown[]) => void) => handlers.push(fn),
    emit: (...args: unknown[]) => handlers.forEach((fn) => fn(...args)),
  };
}
function setup() {
  const ports: {
    onMessage: ReturnType<typeof event>;
    onDisconnect: ReturnType<typeof event>;
    disconnect: ReturnType<typeof vi.fn>;
    postMessage: ReturnType<typeof vi.fn>;
  }[] = [];
  const runtime = {
    lastError: undefined,
    connectNative: vi.fn(() => {
      const onMessage = event(),
        onDisconnect = event();
      const port = {
        onMessage,
        onDisconnect,
        postMessage: vi.fn(),
        disconnect: vi.fn(() => onDisconnect.emit()),
      };
      ports.push(port);
      return port;
    }),
  };
  let alarm: unknown;
  const values: Record<string, unknown> = {};
  const storage = {
    session: {
      get: vi.fn(async () => ({ ...values })),
      set: vi.fn(async (update: Record<string, unknown>) => {
        Object.assign(values, update);
      }),
    },
  };
  const alarms = {
    get: vi.fn(async () => alarm),
    clear: vi.fn(async () => {
      alarm = undefined;
      return true;
    }),
    create: vi.fn(async (_name: string, details: unknown) => {
      alarm = details;
    }),
  };
  vi.stubGlobal("chrome", { runtime, alarms, storage });
  return { ports, runtime, alarms };
}
afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});
it("manual retry replaces an unhealthy port instead of waiting for an alarm", async () => {
  const s = setup();
  const client = new NativeClient(vi.fn(), vi.fn());
  await client.connect();
  s.ports[0].onMessage.emit(
    envelope("connection.status", { connected: false }),
  );
  await client.connect(true);
  expect(s.ports[0].disconnect).toHaveBeenCalled();
  expect(s.runtime.connectNative).toHaveBeenCalledTimes(2);
});
it("rejects malformed messages and stops automatic reconnection", async () => {
  const s = setup();
  const state = vi.fn();
  const client = new NativeClient(vi.fn(), state);
  await client.connect();
  s.ports[0].onMessage.emit({ ...envelope("ping"), v: 99 });
  await client.connect();
  expect(s.runtime.connectNative).toHaveBeenCalledTimes(1);
  expect(s.ports[0].disconnect).toHaveBeenCalled();
  expect(state).toHaveBeenCalledWith(
    false,
    expect.stringContaining("invalid protocol"),
  );
});
it("caps automatic retries and permits an explicit user retry", async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  const s = setup();
  const client = new NativeClient(vi.fn(), vi.fn());
  for (let i = 0; i < 10; i++) {
    await client.connect();
    s.ports.at(-1)?.onDisconnect.emit();
    await new Promise<void>((resolve) => setImmediate(resolve));
    vi.setSystemTime(Date.now() + 300001);
  }
  expect(s.runtime.connectNative).toHaveBeenCalledTimes(9);
  expect(s.alarms.create).toHaveBeenCalledTimes(8);
  await client.connect(true);
  expect(s.runtime.connectNative).toHaveBeenCalledTimes(10);
});

it("persists retry deadlines across service-worker instances", async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  const s = setup();
  let client = new NativeClient(vi.fn(), vi.fn());
  await client.connect();
  s.ports[0].onDisconnect.emit();
  await new Promise<void>((resolve) => setImmediate(resolve));
  client = new NativeClient(vi.fn(), vi.fn());
  await client.connect();
  expect(s.runtime.connectNative).toHaveBeenCalledTimes(1);
  vi.setSystemTime(Date.now() + 30001);
  await client.connect();
  expect(s.runtime.connectNative).toHaveBeenCalledTimes(2);
});
