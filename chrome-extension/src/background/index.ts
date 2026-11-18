import {
  DEFAULT_STATUS,
  PATTERNS,
  envelope,
  type Envelope,
  type Payload,
  type Mode,
  type Status,
} from "../shared/protocol";
import { NativeClient, RECONNECT } from "../native/client";
import { TabFocuser } from "./focus";
let status: Status = { ...DEFAULT_STATUS };
let completed: Record<string, { success: boolean; error?: string }> = {};
const waiting = new Map<
  string,
  {
    resolve: () => void;
    reject: (e: Error) => void;
    timeout: ReturnType<typeof setTimeout>;
  }
>();
const focuser = new TabFocuser({
  tabs: () => chrome.tabs.query({ url: PATTERNS }),
  lastWindow: async () =>
    (await chrome.windows.getLastFocused({ windowTypes: ["normal"] })).id,
  activate: (id) => chrome.tabs.update(id, { active: true }),
  focusWindow: (id) => chrome.windows.update(id, { focused: true }),
  create: async (url, windowId) => {
    if (windowId !== undefined)
      return chrome.tabs.create({ url, active: true, windowId });
    const window = await chrome.windows.create({ url, focused: true });
    if (!window || window.id === undefined)
      throw new Error("Chrome did not create a browser window.");
    const tab =
      window.tabs?.[0] ||
      (await chrome.tabs.query({ windowId: window.id, url: PATTERNS }))[0];
    if (!tab) throw new Error("Chrome did not create an Outlook tab.");
    return tab;
  },
});
const ready = (async () => {
  const saved = await chrome.storage.session.get(["status", "completed"]);
  if (saved.status)
    status = {
      ...DEFAULT_STATUS,
      ...(saved.status as Partial<Status>),
      connected: false,
      monitoring: false,
    };
  if (saved.completed && typeof saved.completed === "object")
    completed = saved.completed as typeof completed;
})();
async function persist() {
  await chrome.storage.session.set({ status, completed });
}
const native = new NativeClient(
  (message) => {
    void receive(message).catch(() => {});
  },
  (connected, error) => {
    status = {
      ...status,
      connected,
      monitoring: connected && status.monitoring,
      error,
    };
    void persist();
    for (const [id, request] of waiting) {
      clearTimeout(request.timeout);
      request.reject(new Error(error || "Mac helper disconnected."));
      waiting.delete(id);
    }
  },
);
async function publishTabs() {
  if (!status.connected) return;
  const webTabOpen = (await chrome.tabs.query({ url: PATTERNS })).length > 0;
  native.send(envelope("connection.status", { connected: true, webTabOpen }));
}
async function receive(message: Envelope) {
  await ready;
  const p = message.payload;
  switch (message.type) {
    case "connection.status":
      status.connected = p.connected === true;
      status.error = p.error;
      if (status.connected) {
        native.send(envelope("preferences.get"));
        await publishTabs();
      }
      break;
    case "preferences.update":
      status = { ...status, ...(p as Partial<Status>) };
      break;
    case "monitoring.status":
      status.monitoring = p.monitoring === true;
      if (p.lastCheck) status.lastCheck = p.lastCheck;
      else delete status.lastCheck;
      if (p.lastEmail) status.lastEmail = p.lastEmail;
      else delete status.lastEmail;
      if (p.error) status.error = p.error;
      break;
    case "mail.new":
      if (p.lastEmail) status.lastEmail = p.lastEmail;
      break;
    case "focus.request": {
      const cached = completed[message.id];
      if (cached) {
        native.send(
          envelope("focus.result", { ...cached, target: "chrome" }, message.id),
        );
        break;
      }
      let result: { success: boolean; error?: string };
      try {
        if (p.target !== "chrome")
          throw new Error("Chrome only handles web focus requests.");
        if (
          !p.manual &&
          (!status.enabled ||
            !status.automaticFocus ||
            !["chrome", "smart"].includes(status.mode))
        )
          throw new Error(
            "Automatic Chrome focus is disabled by the selected mode.",
          );
        await focuser.request(message.id, {
          url: p.preferredURL || status.preferredURL,
          openIfMissing: p.openIfMissing === true,
        });
        result = { success: true };
      } catch (error) {
        result = {
          success: false,
          error:
            error instanceof Error ? error.message : "Chrome focus failed.",
        };
      }
      completed[message.id] = result;
      const ids = Object.keys(completed);
      for (const id of ids.slice(0, Math.max(0, ids.length - 128)))
        delete completed[id];
      await persist();
      native.send(
        envelope("focus.result", { ...result, target: "chrome" }, message.id),
      );
      break;
    }
    case "focus.result": {
      const request = waiting.get(message.id);
      if (request) {
        clearTimeout(request.timeout);
        waiting.delete(message.id);
        p.success
          ? request.resolve()
          : request.reject(new Error(p.error || "Focus failed."));
      }
      break;
    }
    case "ping":
      native.send(envelope("pong", {}, message.id));
      break;
    default:
      break;
  }
  await persist();
}
function request(
  type: "focus.request" | "app.settings",
  payload: Payload = {},
): Promise<void> {
  if (!status.connected)
    return Promise.reject(
      new Error("Open the Mac app and connect the native host first."),
    );
  const message = envelope(type, payload);
  if (type === "app.settings") {
    native.send(message);
    return Promise.resolve();
  }
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      waiting.delete(message.id);
      reject(
        new Error("The Mac app did not acknowledge focus within 25 seconds."),
      );
    }, 25000);
    waiting.set(message.id, { resolve, reject, timeout });
    try {
      native.send(message);
    } catch (error) {
      clearTimeout(timeout);
      waiting.delete(message.id);
      reject(error);
    }
  });
}
chrome.runtime.onMessage.addListener(
  (
    message: { type?: string; action?: string; mode?: Mode; enabled?: boolean },
    sender,
    respond,
  ) => {
    if (
      sender.id !== chrome.runtime.id ||
      !sender.url?.startsWith(chrome.runtime.getURL(""))
    )
      return false;
    if (message?.type !== "ui.status" && message?.type !== "ui.action")
      return false;
    void (async () => {
      await ready;
      if (message.type === "ui.status") return { ok: true, status };
      switch (message.action) {
        case "retry":
          await native.connect(true);
          break;
        case "mode":
          if (
            ![
              "desktop",
              "chrome",
              "smart",
              "notificationOnly",
              "disabled",
            ].includes(message.mode || "")
          )
            throw new Error("Invalid focus mode.");
          if (!status.connected)
            throw new Error("Connect the Mac helper first.");
          native.send(envelope("preferences.update", { mode: message.mode }));
          break;
        case "automatic":
          if (typeof message.enabled !== "boolean")
            throw new Error("Invalid automatic-focus setting.");
          if (!status.connected)
            throw new Error("Connect the Mac helper first.");
          native.send(
            envelope("preferences.update", { automaticFocus: message.enabled }),
          );
          break;
        case "desktop":
          await request("focus.request", { target: "desktop", manual: true });
          break;
        case "chrome":
          if (status.connected)
            await request("focus.request", { target: "chrome", manual: true });
          else
            await focuser.request(crypto.randomUUID(), {
              url: status.preferredURL,
              openIfMissing: false,
            });
          break;
        case "openWeb":
          await focuser.request(crypto.randomUUID(), {
            url: status.preferredURL,
            openIfMissing: true,
          });
          break;
        case "settings":
          await request("app.settings");
          break;
        default:
          throw new Error("Unsupported action.");
      }
      return { ok: true, status };
    })()
      .then(respond)
      .catch((error) =>
        respond({
          ok: false,
          error:
            error instanceof Error ? error.message : "OutlookFocus failed.",
        }),
      );
    return true;
  },
);
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT) void native.connect();
});
chrome.runtime.onStartup.addListener(() => {
  void native.connect(true);
});
chrome.runtime.onInstalled.addListener(() => {
  void native.connect(true);
});
let tabTimer: ReturnType<typeof setTimeout> | undefined;
function tabChanged() {
  if (tabTimer) return;
  tabTimer = setTimeout(() => {
    tabTimer = undefined;
    void publishTabs().catch(() => {});
  }, 250);
}
chrome.tabs.onCreated.addListener(tabChanged);
chrome.tabs.onRemoved.addListener(tabChanged);
chrome.tabs.onUpdated.addListener(tabChanged);
chrome.tabs.onActivated.addListener(tabChanged);
void ready.then(() => native.connect());
