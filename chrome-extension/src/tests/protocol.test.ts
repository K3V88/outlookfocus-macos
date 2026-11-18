import { it, expect } from "vitest";
import { envelope, parseEnvelope, outlookURL } from "../shared/protocol";
import { retryDelay } from "../native/client";
it("round-trips the versioned message envelope", () => {
  const m = envelope("focus.request", { target: "chrome", manual: true });
  expect(parseEnvelope(JSON.parse(JSON.stringify(m)))).toEqual(m);
});
it.each([
  "https://outlook.office.com/",
  "https://outlook.live.com/mail/",
  "https://outlook.office365.com/mail/",
  "https://outlook.cloud.microsoft/mail/",
])("accepts Microsoft Outlook host %s", (url) =>
  expect(outlookURL(url)).toBe(true),
);
it.each([
  "https://outlook.office.com.evil.invalid/",
  "http://outlook.office.com/",
  "https://user@outlook.live.com/",
  "https://outlook.live.com:444/",
  "javascript:alert(1)",
])("rejects destination %s", (url) => expect(outlookURL(url)).toBe(false));
it("rejects tokens, arbitrary commands, invalid versions and missing correlation IDs", () => {
  expect(parseEnvelope({ ...envelope("ping"), v: 2 })).toBeNull();
  expect(parseEnvelope({ ...envelope("ping"), id: "not-a-uuid" })).toBeNull();
  expect(
    parseEnvelope({
      ...envelope("ping"),
      payload: { accessToken: "never-send-tokens" },
    }),
  ).toBeNull();
  expect(
    parseEnvelope({
      ...envelope("focus.request", { target: "chrome" }),
      payload: { target: "chrome", shellCommand: "whoami" },
    }),
  ).toBeNull();
});
it("rejects invalid payload types and unauthorized URLs", () => {
  expect(
    parseEnvelope({
      ...envelope("preferences.update"),
      payload: { enabled: "yes" },
    }),
  ).toBeNull();
  expect(
    parseEnvelope(
      envelope("focus.request", {
        target: "chrome",
        preferredURL: "https://evil.invalid",
      }),
    ),
  ).toBeNull();
  expect(
    parseEnvelope({ ...envelope("focus.result"), payload: {} }),
  ).toBeNull();
});
it("rejects oversized messages", () =>
  expect(
    parseEnvelope(envelope("connection.status", { error: "x".repeat(70000) })),
  ).toBeNull());
it("reconnects with a Chrome-supported bounded alarm delay", () => {
  expect(retryDelay(1)).toBe(0.5);
  expect(retryDelay(2)).toBe(1);
  expect(retryDelay(8)).toBe(5);
});
