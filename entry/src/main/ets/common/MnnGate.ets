// SemSearch: process-wide serialization gate for the shared MNN engine.
// The native g_embedding instance in libentry.so is a process-wide static:
// its MNN session (thread pool + llm session) is NOT internally locked. Two
// concurrent forwards on it either starve the caller — a main-thread embed
// during a taskpool imgEmbed blocks past the THREAD_BLOCK_6S watchdog and
// the system kills the app (appfreeze observed 2026-10-21) — or corrupt the
// session. Every ArkTS caller that touches the engine — the main-thread
// embed()/embedDoc() on both pages and every taskpool init/initVisual/
// imgEmbed dispatch (see EmbedTasks.ets) — must hold this gate across the
// whole native call. Acquire is an async wait, so the UI thread stays
// responsive while queued behind a long encode. FIFO handoff: release()
// transfers ownership directly to the next waiter.
export class MnnGateImpl {
  private active: boolean = false;
  private waiters: Array<() => void> = [];

  async acquire(): Promise<void> {
    if (!this.active) {
      this.active = true;
      return;
    }
    await new Promise<void>((resolve: () => void) => {
      this.waiters.push(resolve);
    });
  }

  release(): void {
    const next: (() => void) | undefined = this.waiters.shift();
    if (next !== undefined) {
      // ownership transfers to the next waiter; active stays true
      next();
    } else {
      this.active = false;
    }
  }
}

export const MnnGate: MnnGateImpl = new MnnGateImpl();
