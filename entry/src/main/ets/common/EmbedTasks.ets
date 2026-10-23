// SemSearch: heavy NAPI embedding calls wrapped as taskpool concurrent tasks.
// Rationale: on the x86 emulator a single imgEmbed takes 22-65s and a cold
// init() takes 11s+. Calling them synchronously on the JS (UI) thread blocks
// the main thread far beyond the system THREAD_BLOCK_6S watchdog threshold,
// and the system kills the app (appfreeze -> SIGKILL). Running the same NAPI
// calls inside a taskpool worker keeps the UI thread responsive; the native
// g_embedding instance is a process-wide static inside libentry.so, so worker
// threads share it (initVisual dedups an already-loaded dir instantly).
// NOTE: do not run text embed()/embedDoc() on the main thread concurrently
// with these tasks — the underlying MNN session is not internally locked.
// Every engine call site (both pages + PhotoIndexManager) serializes through
// the process-wide MnnGate (common/MnnGate.ets).
import { init, initVisual, imgEmbed, isLoaded } from 'libentry.so';

@Concurrent
export function initTask(modelDir: string): boolean {
  if (!init(modelDir)) {
    return false;
  }
  return isLoaded();
}

@Concurrent
export function visualInitTask(modelDir: string): boolean {
  if (!initVisual(modelDir)) {
    return false;
  }
  return isLoaded();
}

@Concurrent
export function imgEmbedTask(imagePath: string): Float32Array {
  return imgEmbed(imagePath);
}
