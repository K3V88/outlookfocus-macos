export type Mode =
  | "desktop"
  | "chrome"
  | "smart"
  | "notificationOnly"
  | "disabled";
export type Target = "desktop" | "chrome";
export type MessageType =
  | "hello"
  | "connection.status"
  | "monitoring.status"
  | "mail.new"
  | "focus.request"
  | "focus.result"
  | "preferences.get"
  | "preferences.update"
  | "app.settings"
  | "ping"
  | "pong";
export interface Payload {
  connected?: boolean;
  monitoring?: boolean;
  mode?: Mode;
  enabled?: boolean;
  automaticFocus?: boolean;
  webTabOpen?: boolean;
  target?: Target;
  success?: boolean;
  error?: string;
  openIfMissing?: boolean;
  manual?: boolean;
  preferredURL?: string;
  origin?: string;
  count?: number;
  lastEmail?: string;
  lastCheck?: string;
}
export interface Envelope {
  v: 1;
  type: MessageType;
  id: string;
  timestamp: string;
  payload: Payload;
}
export const HOST = "com.k3v88.outlookfocus.host";
export const HOSTS = [
  "outlook.office.com",
  "outlook.live.com",
  "outlook.office365.com",
  "outlook.cloud.microsoft",
];
export const PATTERNS = HOSTS.map((host) => `https://${host}/*`);
export function outlookURL(value: unknown): boolean {
  if (typeof value !== "string") return false;
  try {
    const u = new URL(value);
    return (
      u.protocol === "https:" &&
      HOSTS.includes(u.hostname) &&
      !u.username &&
      !u.password &&
      (!u.port || u.port === "443")
    );
  } catch {
    return false;
  }
}
export function envelope(
  type: MessageType,
  payload: Payload = {},
  id: string = crypto.randomUUID(),
): Envelope {
  return { v: 1, type, id, timestamp: new Date().toISOString(), payload };
}
const fields: Record<MessageType, string[]> = {
  hello: ["origin"],
  "connection.status": ["connected", "webTabOpen", "error"],
  "monitoring.status": ["monitoring", "lastCheck", "lastEmail", "error"],
  "mail.new": ["count", "lastEmail"],
  "focus.request": ["target", "openIfMissing", "preferredURL", "manual"],
  "focus.result": ["success", "error", "target"],
  "preferences.get": [],
  "preferences.update": [
    "mode",
    "enabled",
    "automaticFocus",
    "openIfMissing",
    "preferredURL",
  ],
  "app.settings": [],
  ping: [],
  pong: [],
};
export function parseEnvelope(input: unknown): Envelope | null {
  try {
    if (!input || typeof input !== "object" || Array.isArray(input))
      return null;
    const m = input as Record<string, unknown>;
    if (
      new TextEncoder().encode(JSON.stringify(m)).length > 65536 ||
      Object.keys(m).sort().join(",") !== "id,payload,timestamp,type,v" ||
      m.v !== 1 ||
      typeof m.type !== "string" ||
      !Object.hasOwn(fields, m.type) ||
      typeof m.id !== "string" ||
      !/^[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i.test(
        m.id,
      ) ||
      typeof m.timestamp !== "string" ||
      !Number.isFinite(Date.parse(m.timestamp)) ||
      !m.payload ||
      typeof m.payload !== "object" ||
      Array.isArray(m.payload)
    )
      return null;
    const p = m.payload as Record<string, unknown>,
      type = m.type as MessageType;
    for (const [key, value] of Object.entries(p)) {
      if (!fields[type].includes(key)) return null;
      if (
        [
          "connected",
          "monitoring",
          "enabled",
          "automaticFocus",
          "webTabOpen",
          "success",
          "openIfMissing",
          "manual",
        ].includes(key) &&
        typeof value !== "boolean"
      )
        return null;
      if (
        [
          "error",
          "origin",
          "preferredURL",
          "mode",
          "target",
          "lastEmail",
          "lastCheck",
        ].includes(key) &&
        (typeof value !== "string" || value.length > 500)
      )
        return null;
      if (
        key === "count" &&
        (!Number.isInteger(value) ||
          Number(value) < 0 ||
          Number(value) > 100000)
      )
        return null;
      if (key === "preferredURL" && !outlookURL(value)) return null;
      if (
        key === "mode" &&
        ![
          "desktop",
          "chrome",
          "smart",
          "notificationOnly",
          "disabled",
        ].includes(String(value))
      )
        return null;
      if (key === "target" && !["desktop", "chrome"].includes(String(value)))
        return null;
      if (
        key === "origin" &&
        !/^chrome-extension:\/\/[a-p]{32}\/$/.test(String(value))
      )
        return null;
      if (
        ["lastEmail", "lastCheck"].includes(key) &&
        !Number.isFinite(Date.parse(String(value)))
      )
        return null;
    }
    if (
      (type === "hello" && p.origin === undefined) ||
      (type === "focus.request" && p.target === undefined) ||
      (type === "focus.result" && p.success === undefined)
    )
      return null;
    return input as Envelope;
  } catch {
    return null;
  }
}
export interface Status {
  connected: boolean;
  monitoring: boolean;
  mode: Mode;
  enabled: boolean;
  automaticFocus: boolean;
  openIfMissing: boolean;
  preferredURL: string;
  lastEmail?: string;
  lastCheck?: string;
  error?: string;
}
export const DEFAULT_STATUS: Status = {
  connected: false,
  monitoring: false,
  mode: "smart",
  enabled: false,
  automaticFocus: true,
  openIfMissing: false,
  preferredURL: "https://outlook.office.com/mail/",
};
