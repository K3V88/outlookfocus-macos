import type { Status, Mode } from "../shared/protocol";
const $ = <T extends HTMLElement>(id: string) =>
  document.getElementById(id) as T;
function time(value?: string) {
  return value
    ? new Date(value).toLocaleTimeString([], {
        hour: "2-digit",
        minute: "2-digit",
      })
    : "None yet";
}
function render(s: Status) {
  $("connection").textContent = s.connected
    ? "Connected to Mac Helper"
    : "Mac Helper Disconnected";
  $("monitoring").textContent = s.connected
    ? s.monitoring
      ? "Active"
      : "Paused / account setup needed"
    : "Unknown";
  $("last-email").textContent = time(s.lastEmail);
  $("last-check").textContent = time(s.lastCheck);
  $<HTMLInputElement>("automatic").checked = s.automaticFocus;
  $<HTMLInputElement>("automatic").disabled = !s.connected;
  $<HTMLSelectElement>("mode").value = s.mode;
  $<HTMLSelectElement>("mode").disabled = !s.connected;
  for (const id of ["desktop", "settings", "smart"])
    $<HTMLButtonElement>(id).disabled = !s.connected;
  $("error").textContent = s.error || "";
}
async function refresh() {
  const reply = await chrome.runtime.sendMessage({ type: "ui.status" });
  if (reply?.ok) render(reply.status);
}
async function action(action: string, extra: Record<string, unknown> = {}) {
  try {
    const reply = await chrome.runtime.sendMessage({
      type: "ui.action",
      action,
      ...extra,
    });
    if (!reply?.ok) throw new Error(reply?.error || "Action failed.");
    await refresh();
  } catch (error) {
    $("error").textContent =
      error instanceof Error ? error.message : String(error);
  }
}
$<HTMLInputElement>("automatic").addEventListener(
  "change",
  (e) =>
    void action("automatic", {
      enabled: (e.target as HTMLInputElement).checked,
    }),
);
$<HTMLSelectElement>("mode").addEventListener(
  "change",
  (e) =>
    void action("mode", {
      mode: (e.target as HTMLSelectElement).value as Mode,
    }),
);
for (const [id, name] of [
  ["desktop", "desktop"],
  ["chrome", "chrome"],
  ["open-web", "openWeb"],
  ["settings", "settings"],
  ["retry", "retry"],
])
  $(id).addEventListener("click", () => void action(name));
$("smart").addEventListener(
  "click",
  () => void action("mode", { mode: "smart" }),
);
void refresh().catch(() => {
  $("error").textContent =
    "Could not contact the extension. Reload it in chrome://extensions.";
});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "session" && changes.status)
    render(changes.status.newValue as Status);
});
