import { it, expect, vi } from "vitest";
import { TabFocuser, type Browser, type Tab } from "../background/focus";
function browser(initial: Tab[] = []) {
  let tabs = [...initial];
  const api: Browser = {
    tabs: vi.fn(async () => tabs),
    lastWindow: vi.fn(async () => 4),
    activate: vi.fn(async () => {}),
    focusWindow: vi.fn(async () => {}),
    create: vi.fn(async (url, windowId) => {
      const tab = { id: 99, windowId: windowId ?? 4, url };
      tabs = [...tabs, tab];
      return tab;
    }),
  };
  return api;
}
it("activates an existing Outlook tab and its containing window", async () => {
  const b = browser([
    { id: 3, windowId: 4, url: "https://outlook.office.com/mail/" },
  ]);
  const f = new TabFocuser(b);
  expect(
    await f.request("event", {
      url: "https://outlook.office.com/mail/",
      openIfMissing: false,
    }),
  ).toEqual({ tabId: 3, windowId: 4, created: false });
  expect(b.activate).toHaveBeenCalledWith(3);
  expect(b.focusWindow).toHaveBeenCalledWith(4);
  expect(b.create).not.toHaveBeenCalled();
});
it("prefers the configured Outlook host across multiple windows", async () => {
  const b = browser([
    { id: 1, windowId: 4, url: "https://outlook.live.com/mail/", active: true },
    { id: 2, windowId: 8, url: "https://outlook.office.com/mail/" },
  ]);
  await new TabFocuser(b).request("x", {
    url: "https://outlook.office.com/mail/",
    openIfMissing: false,
  });
  expect(b.activate).toHaveBeenCalledWith(2);
});
it("reports missing tabs instead of opening without permission", async () => {
  const b = browser();
  await expect(
    new TabFocuser(b).request("x", {
      url: "https://outlook.office.com/mail/",
      openIfMissing: false,
    }),
  ).rejects.toThrow("No Outlook Web tab");
  expect(b.create).not.toHaveBeenCalled();
});
it("serializes concurrent events and avoids duplicate tabs", async () => {
  const b = browser();
  const f = new TabFocuser(b);
  const options = {
    url: "https://outlook.office.com/mail/",
    openIfMissing: true,
  };
  const [a, c] = await Promise.all([
    f.request("one", options),
    f.request("two", options),
  ]);
  expect(a.tabId).toBe(c.tabId);
  expect(b.create).toHaveBeenCalledTimes(1);
});
it("deduplicates event IDs including in-flight requests", async () => {
  const b = browser();
  const f = new TabFocuser(b);
  const options = {
    url: "https://outlook.office.com/mail/",
    openIfMissing: true,
  };
  await Promise.all([f.request("one", options), f.request("one", options)]);
  expect(b.create).toHaveBeenCalledTimes(1);
  expect(b.activate).toHaveBeenCalledTimes(1);
});
it("rejects unrelated sites even if supplied by a helper", async () => {
  const b = browser();
  await expect(
    new TabFocuser(b).request("x", {
      url: "https://evil.invalid/",
      openIfMissing: true,
    }),
  ).rejects.toThrow("verified Outlook");
  expect(b.create).not.toHaveBeenCalled();
});
it("handles no existing Chrome window and window activation errors", async () => {
  const b = browser();
  b.lastWindow = vi.fn(async () => undefined);
  b.focusWindow = vi.fn(async () => {
    throw new Error("Window is gone");
  });
  await expect(
    new TabFocuser(b).request("x", {
      url: "https://outlook.live.com/mail/",
      openIfMissing: true,
    }),
  ).rejects.toThrow("Window is gone");
  expect(b.create).toHaveBeenCalledWith(
    "https://outlook.live.com/mail/",
    undefined,
  );
});
