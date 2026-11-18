import { chromium } from "@playwright/test";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { spawn } from "node:child_process";
import { resolve, join } from "node:path";
const root = resolve("..");
export async function harness() {
  const temporary = await mkdtemp("/private/tmp/mailfocus-browser-");
  const profile = join(temporary, "profile"),
    support = join(temporary, "support");
  await mkdir(support, { mode: 0o700 });
  let fixture;
  async function startFixture() {
    fixture = spawn(resolve(root, ".build/debug/BridgeFixture"), [support], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(new Error("Bridge fixture did not start")),
        10000,
      );
      fixture.stderr.on("data", (data) => {
        if (data.toString().includes("BRIDGE_READY")) {
          clearTimeout(timeout);
          resolve();
        }
      });
      fixture.once("exit", (code) => {
        if (code) {
          clearTimeout(timeout);
          reject(new Error("Bridge fixture exited: " + code));
        }
      });
    });
  }
  async function stopFixture() {
    if (fixture && !fixture.killed) {
      const stopped = new Promise((r) => fixture.once("exit", r));
      fixture.kill("SIGTERM");
      await stopped;
    }
  }
  await startFixture();
  const context = await chromium.launchPersistentContext(profile, {
    channel: "chromium",
    headless: true,
    ignoreDefaultArgs: ["--disable-extensions"],
    args: [
      "--enable-unsafe-extension-debugging",
      "--host-resolver-rules=MAP * ~NOTFOUND",
    ],
    env: { ...process.env, MAILFOCUS_TEST_SUPPORT_DIR: support },
  });
  // No Microsoft account/network requests: tabs are deterministic browser fixtures.
  await context.route("https://**/*", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: "<!doctype html><title>MailFocus integration fixture</title><h1>Public test fixture, no email content</h1>",
    }),
  );
  const cdp = await context.browser().newBrowserCDPSession();
  const { id } = await cdp.send("Extensions.loadUnpacked", {
    path: resolve("dist"),
  });
  const origin = `chrome-extension://${id}/`;
  await writeFile(
    join(support, "allowed-origins.json"),
    JSON.stringify([origin]),
    { mode: 0o600 },
  );
  await mkdir(join(profile, "NativeMessagingHosts"), { recursive: true });
  await writeFile(
    join(profile, "NativeMessagingHosts/com.k3v88.mailfocus.host.json"),
    JSON.stringify({
      name: "com.k3v88.mailfocus.host",
      description: "MailFocus isolated integration fixture",
      path: resolve(root, ".build/debug/MailFocusNativeHost"),
      type: "stdio",
      allowed_origins: [origin],
    }),
  );
  const worker =
    context.serviceWorkers()[0] ||
    (await context.waitForEvent("serviceworker"));
  const source = await context.newPage();
  await source.goto("https://example.test/");
  async function popup(page = source) {
    await page.bringToFront();
    const { targetInfos } = await cdp.send("Target.getTargets", {
      filter: [{ type: "tab", exclude: false }, { exclude: true }],
    });
    const target = targetInfos.find((t) => t.url === page.url());
    if (!target) throw new Error("No source browser tab");
    await cdp.send("Extensions.triggerAction", {
      id,
      targetId: target.targetId,
    });
    let popupTarget;
    for (let i = 0; i < 100; i++) {
      const result = await cdp.send("Target.getTargets");
      popupTarget = result.targetInfos.find(
        (t) => t.url === `chrome-extension://${id}/popup.html`,
      );
      if (popupTarget) break;
      await new Promise((r) => setTimeout(r, 30));
    }
    if (!popupTarget) throw new Error("Toolbar popup not found");
    const { sessionId } = await cdp.send("Target.attachToTarget", {
      targetId: popupTarget.targetId,
      flatten: false,
    });
    let sequence = 0;
    const pending = new Map();
    const receive = (e) => {
      if (e.sessionId !== sessionId) return;
      const reply = JSON.parse(e.message);
      const task = pending.get(reply.id);
      if (task) {
        clearTimeout(task.timer);
        pending.delete(reply.id);
        reply.error
          ? task.reject(new Error(reply.error.message))
          : task.resolve(reply.result);
      }
    };
    cdp.on("Target.receivedMessageFromTarget", receive);
    async function evaluate(fn, arg) {
      const n = ++sequence;
      const result = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(n);
          reject(new Error("Popup timed out"));
        }, 10000);
        pending.set(n, { resolve, reject, timer });
        cdp
          .send("Target.sendMessageToTarget", {
            sessionId,
            message: JSON.stringify({
              id: n,
              method: "Runtime.evaluate",
              params: {
                expression: `(${fn.toString()})(${JSON.stringify(arg) ?? "undefined"})`,
                awaitPromise: true,
                returnByValue: true,
              },
            }),
          })
          .catch(reject);
      });
      if (result.exceptionDetails)
        throw new Error(
          result.exceptionDetails.exception?.description ||
            result.exceptionDetails.text,
        );
      return result.result.value;
    }
    for (let i = 0; i < 100; i++) {
      if (
        await evaluate(
          () =>
            document.readyState === "complete" &&
            document.querySelector("#connection")?.textContent !==
              "Connecting to Mac helper…" &&
            !!document.querySelector("#retry"),
        )
      )
        break;
      await new Promise((r) => setTimeout(r, 30));
    }
    return {
      evaluate,
      async click(id) {
        await evaluate((id) => {
          setTimeout(() => document.getElementById(id).click(), 0);
        }, id);
      },
      async close() {
        cdp.off("Target.receivedMessageFromTarget", receive);
        await cdp
          .send("Target.closeTarget", { targetId: popupTarget.targetId })
          .catch(() => {});
      },
    };
  }
  return {
    context,
    worker,
    source,
    id,
    popup,
    startFixture,
    stopFixture,
    async close() {
      await context.close();
      await stopFixture();
      await rm(temporary, { recursive: true, force: true });
    },
  };
}
