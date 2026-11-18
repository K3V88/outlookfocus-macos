import { outlookURL } from "../shared/protocol";
export interface Tab {
  id?: number;
  windowId: number;
  url?: string;
  active?: boolean;
}
export interface Browser {
  tabs: () => Promise<Tab[]>;
  lastWindow: () => Promise<number | undefined>;
  activate: (id: number) => Promise<unknown>;
  focusWindow: (id: number) => Promise<unknown>;
  create: (url: string, windowId?: number) => Promise<Tab>;
}
export interface FocusResult {
  tabId: number;
  windowId: number;
  created: boolean;
}
export class TabFocuser {
  private chain: Promise<unknown> = Promise.resolve();
  private completed = new Map<string, Promise<FocusResult>>();
  constructor(private browser: Browser) {}
  request(
    id: string,
    options: { url: string; openIfMissing: boolean },
  ): Promise<FocusResult> {
    const old = this.completed.get(id);
    if (old) return old;
    const work = this.chain.catch(() => {}).then(() => this.focus(options));
    this.chain = work;
    this.completed.set(id, work);
    if (this.completed.size > 128)
      this.completed.delete(this.completed.keys().next().value!);
    return work;
  }
  private async focus({
    url,
    openIfMissing,
  }: {
    url: string;
    openIfMissing: boolean;
  }): Promise<FocusResult> {
    if (!outlookURL(url))
      throw new Error("Only verified Outlook Web hosts are allowed.");
    const current = await this.browser.lastWindow().catch(() => undefined);
    const tabs = (await this.browser.tabs()).filter(
      (t) => t.id !== undefined && outlookURL(t.url),
    );
    const preferred = new URL(url).hostname;
    const score = (tab: Tab) =>
      (tab.url && new URL(tab.url).hostname === preferred ? 20 : 0) +
      (tab.windowId === current ? 8 : 0) +
      (tab.active ? 2 : 0);
    tabs.sort((a, b) => score(b) - score(a));
    let tab = tabs[0];
    let created = false;
    if (!tab) {
      if (!openIfMissing)
        throw new Error(
          "No Outlook Web tab exists. Enable opening missing tabs in the Mac app or use Open Outlook Web.",
        );
      tab = await this.browser.create(url, current);
      created = true;
    }
    if (tab.id === undefined)
      throw new Error("Chrome did not return a tab identifier.");
    await this.browser.activate(tab.id);
    await this.browser.focusWindow(tab.windowId);
    return { tabId: tab.id, windowId: tab.windowId, created };
  }
}
