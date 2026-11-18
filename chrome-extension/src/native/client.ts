import { HOST, parseEnvelope, type Envelope } from "../shared/protocol";
export const RECONNECT = "mailfocus.reconnect";
export function retryDelay(attempt: number): number {
  return Math.min(5, 0.5 * 2 ** Math.max(0, attempt - 1));
}
export class NativeClient {
  private port: chrome.runtime.Port | undefined;
  private attempts = 0;
  private stopped = false;
  private helperReady = false;
  private retryAt = 0;
  private initialized: Promise<void>;
  constructor(
    private received: (message: Envelope) => void,
    private state: (connected: boolean, error?: string) => void,
  ) {
    this.initialized = this.restore().catch(() => {
      this.stopped = true;
      this.state(
        false,
        "Could not restore connection state. Retry Connection.",
      );
    });
  }
  private async restore() {
    const stored = (await chrome.storage.session.get("nativeRetry"))
      .nativeRetry as
      | { attempts?: unknown; stopped?: unknown; retryAt?: unknown }
      | undefined;
    if (
      stored &&
      Number.isInteger(stored.attempts) &&
      Number(stored.attempts) >= 0 &&
      Number(stored.attempts) <= 9 &&
      typeof stored.stopped === "boolean"
    ) {
      this.attempts = Number(stored.attempts);
      this.stopped = stored.stopped;
      this.retryAt =
        typeof stored.retryAt === "number" && Number.isFinite(stored.retryAt)
          ? stored.retryAt
          : 0;
      if (
        !this.stopped &&
        this.retryAt > Date.now() &&
        !(await chrome.alarms.get(RECONNECT))
      ) {
        await chrome.alarms.create(RECONNECT, { when: this.retryAt });
      }
    }
  }
  private async saveRetries() {
    try {
      await chrome.storage.session.set({
        nativeRetry: {
          attempts: this.attempts,
          stopped: this.stopped,
          retryAt: this.retryAt,
        },
      });
      return true;
    } catch {
      this.stopped = true;
      this.state(false, "Could not save connection state. Retry Connection.");
      return false;
    }
  }
  async connect(reset = false) {
    await this.initialized;
    if (reset) {
      this.attempts = 0;
      this.stopped = false;
      this.retryAt = 0;
      if (!(await this.saveRetries())) return;
      await chrome.alarms.clear(RECONNECT);
    }
    if (reset && this.port && !this.helperReady) {
      const old = this.port;
      this.port = undefined;
      old.disconnect();
    }
    if (this.port || this.stopped || this.retryAt > Date.now()) return;
    try {
      const port = chrome.runtime.connectNative(HOST);
      this.port = port;
      port.onMessage.addListener((value: unknown) => {
        if (this.port !== port) return;
        const message = parseEnvelope(value);
        if (!message) {
          this.state(
            false,
            "The native helper sent an invalid protocol message.",
          );
          this.stopped = true;
          void this.saveRetries();
          port.disconnect();
          return;
        }
        if (message.type === "connection.status")
          this.helperReady = message.payload.connected === true;
        if (message.type === "connection.status" && message.payload.connected) {
          this.attempts = 0;
          this.retryAt = 0;
          void this.saveRetries();
          void chrome.alarms.clear(RECONNECT);
        }
        this.received(message);
      });
      port.onDisconnect.addListener(() => {
        if (this.port !== port) return;
        this.port = undefined;
        this.helperReady = false;
        const error = chrome.runtime.lastError?.message;
        this.state(false, error || "The Mac helper disconnected.");
        void this.schedule();
      });
    } catch {
      this.state(
        false,
        "Native messaging could not start. Install the native host.",
      );
      await this.schedule();
    }
  }
  private async schedule() {
    if (this.stopped) return;
    this.attempts++;
    if (this.attempts > 8) {
      this.stopped = true;
      this.retryAt = 0;
      await this.saveRetries();
      this.state(
        false,
        "Connection retries paused. Open MailFocus on your Mac, then click Retry Connection.",
      );
      return;
    }
    this.retryAt = Date.now() + retryDelay(this.attempts) * 60000;
    if (await this.saveRetries())
      await chrome.alarms.create(RECONNECT, { when: this.retryAt });
  }
  send(message: Envelope) {
    if (!this.port) throw new Error("Mac helper is disconnected.");
    this.port.postMessage(message);
  }
}
