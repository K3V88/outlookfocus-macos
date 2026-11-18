import { test, expect } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { harness } from "./harness.mjs";
let app;
const state = () =>
  app.worker.evaluate(
    async () => (await chrome.storage.session.get("status")).status,
  );
test.beforeAll(async () => {
  app = await harness();
  const popup = await app.popup();
  await popup.click("retry");
  await expect
    .poll(async () => (await state())?.connected, { timeout: 15000 })
    .toBe(true);
  await popup.close();
});
test.afterAll(async () => {
  await app?.close();
});
test.afterEach(async () => {
  for (const p of app.context.pages()) if (p !== app.source) await p.close();
});
test("real native process connects through the isolated Chrome manifest and user-only socket", async () => {
  const s = await state();
  expect(s.connected).toBe(true);
  expect(s.mode).toBe("chrome");
  const popup = await app.popup();
  await expect
    .poll(() =>
      popup.evaluate(() => document.querySelector("#connection").textContent),
    )
    .toBe("Connected to Mac Helper");
  expect(
    await popup.evaluate(() => document.querySelector("#desktop").disabled),
  ).toBe(false);
  const json = JSON.stringify(s);
  expect(json).not.toMatch(/accessToken|refreshToken|subject|messageBody/);
  await popup.close();
});
test("existing Outlook tab is activated through native framing, fixture routing and acknowledgement", async () => {
  const outlook = await app.context.newPage();
  await outlook.goto("https://outlook.office.com/mail/");
  const info = await app.worker.evaluate(async () => {
    const [tab] = await chrome.tabs.query({
      url: "https://outlook.office.com/*",
    });
    return { id: tab.id, windowId: tab.windowId };
  });
  const popup = await app.popup();
  await popup.click("chrome");
  await expect
    .poll(() =>
      app.worker.evaluate(async () => {
        const [tab] = await chrome.tabs.query({
          active: true,
          currentWindow: true,
        });
        return tab.id;
      }),
    )
    .toBe(info.id);
  await expect
    .poll(async () => {
      const completed = await app.worker.evaluate(
        async () => (await chrome.storage.session.get("completed")).completed,
      );
      return Object.values(completed || {}).some((r) => r.success);
    })
    .toBe(true);
  await popup.close();
});
test("missing tabs do not open automatically; explicit Open Outlook Web reuses a tab", async () => {
  const popup = await app.popup();
  await popup.click("chrome");
  await expect
    .poll(() =>
      popup.evaluate(() => document.querySelector("#error").textContent),
    )
    .toContain("No Outlook Web tab");
  const before = app.context.pages().length;
  expect(before).toBe(1);
  const opened = app.context.waitForEvent("page");
  await popup.click("open-web");
  const page = await opened;
  await expect(page).toHaveURL("https://outlook.office.com/mail/");
  await popup.close();
  const again = await app.popup();
  await again.click("open-web");
  await expect
    .poll(() =>
      app.worker.evaluate(
        async () =>
          (await chrome.tabs.query({ url: "https://outlook.office.com/*" }))
            .length,
      ),
    )
    .toBe(1);
  await again.close();
});
test("native-host loss is visible and retry reconnects after the Mac bridge restarts", async () => {
  await app.stopFixture();
  await expect.poll(async () => (await state())?.connected).toBe(false);
  let popup = await app.popup();
  await expect
    .poll(() =>
      popup.evaluate(() => document.querySelector("#desktop").disabled),
    )
    .toBe(true);
  await popup.close();
  await app.startFixture();
  popup = await app.popup();
  await popup.click("retry");
  await expect
    .poll(async () => (await state())?.connected, { timeout: 15000 })
    .toBe(true);
  await popup.close();
});
test("capture extension appearance without real email or credentials", async () => {
  await mkdir("../docs", { recursive: true });
  const popup = await app.context.newPage({
    viewport: { width: 370, height: 760 },
  });
  await popup.goto(`chrome-extension://${app.id}/popup.html`);
  await expect(popup.locator("#connection")).toHaveText(
    "Connected to Mac Helper",
  );
  await popup.locator("body").screenshot({ path: "../docs/chrome-popup.png" });
  await popup.close();
});
