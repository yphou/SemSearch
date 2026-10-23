// FR-009 (revised 2026-10-21): offline packaging — the eg2v_int8 model (~647MB,
// 9 files) and the album seed set (20 jpg + manifest.json) ship inside the HAP
// rawfile. On first launch they are streamed once into the app sandbox; the
// LAN HTTP download stays as an optional fallback (Index.ets / Album.ets).
//
// Large rawfile entries MUST be read via resourceManager.getRawFdSync() +
// chunked fileIo.readSync/writeSync on the returned {fd, offset, length}:
// getRawFileContent* would load the whole 600MB into the JS heap and OOM the
// process. (SDK d.ts, API 26: getRawFdSync(path): RawFileDescriptor
// {fd:number, offset:number, length:number}, @since 10; the doc mandates
// closeRawFdSync(path) after use.)
//
// Threading: the chunked copy runs on the host page's async flow (Promise +
// setTimeout yields between chunks). Each 8MB read+write pair blocks the UI
// thread for only tens of ms and the yield between chunks lets the progress UI
// render, so no single block approaches the THREAD_BLOCK_6S watchdog
// threshold. The heavy NAPI calls (init/initVisual/imgEmbed) are untouched in
// their taskpool workers (EmbedTasks.ets).
//
// Idempotency/integrity: a destination file that already exists with the exact
// packaged size is skipped; size mismatches (interrupted copy, killed process)
// are deleted and re-copied. A restart therefore resumes by completing only
// the missing/incomplete files.
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

const TAG: string = 'SemSearch';
// 8MB per chunk: low syscall count for the 268MB weight files, while a single
// synchronous read+write pair stays far below the thread-block threshold.
const CHUNK_SIZE: number = 8 * 1024 * 1024;

export interface RawCopyProgress {
  fileIndex: number;   // 1-based index of the current file in the set
  fileCount: number;   // total files in the set
  fileName: string;    // current file name
  copiedBytes: number; // bytes copied so far for the current file
  fileTotal: number;   // total bytes of the current file
}

// packaged seed manifest (rawfile/album_seed/manifest.json)
interface RawSeedManifest {
  files: string[];
}

export class RawInstaller {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  // Whether a packaged rawfile entry exists (missing entries throw or return
  // an invalid fd from getRawFdSync).
  hasRawEntry(rawPath: string): boolean {
    try {
      const rawFd: resourceManager.RawFileDescriptor =
        this.context.resourceManager.getRawFdSync(rawPath);
      const exists: boolean = rawFd.fd >= 0 && rawFd.length > 0;
      if (exists) {
        try {
          this.context.resourceManager.closeRawFdSync(rawPath);
        } catch (ignored) {
        }
      }
      return exists;
    } catch (e) {
      return false;
    }
  }

  // Stream one rawfile entry to destPath in CHUNK_SIZE pieces. Skips the copy
  // when destPath already holds a complete file of the exact packaged size
  // (idempotent resume). Throws on short read or post-copy size mismatch;
  // mismatched leftovers are deleted so the next run re-copies them.
  private async copyRawFile(rawPath: string, destPath: string, fileName: string,
    fileIndex: number, fileCount: number,
    onProgress: (p: RawCopyProgress) => void): Promise<void> {
    const rm: resourceManager.ResourceManager = this.context.resourceManager;
    const rawFd: resourceManager.RawFileDescriptor = rm.getRawFdSync(rawPath);
    try {
      if (rawFd.fd < 0 || rawFd.length <= 0) {
        throw new Error(`rawfile entry unavailable: ${rawPath}`);
      }
      if (fileIo.accessSync(destPath)) {
        const st: fileIo.Stat = fileIo.statSync(destPath);
        if (st.size === rawFd.length) {
          // already complete (previous run or HTTP download) — nothing to do
          onProgress({
            fileIndex: fileIndex, fileCount: fileCount, fileName: fileName,
            copiedBytes: rawFd.length, fileTotal: rawFd.length
          });
          return;
        }
        // incomplete leftover from an interrupted run — redo it
        fileIo.unlinkSync(destPath);
      }
      const dest: fileIo.File = fileIo.openSync(destPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      let copied: number = 0;
      try {
        while (copied < rawFd.length) {
          const want: number = Math.min(CHUNK_SIZE, rawFd.length - copied);
          const buf: ArrayBuffer = new ArrayBuffer(want);
          // read at the rawfile's absolute position inside the HAP file
          const n: number = fileIo.readSync(rawFd.fd, buf, { offset: rawFd.offset + copied, length: want });
          if (n !== want) {
            throw new Error(`short read ${n}/${want} on ${rawPath}`);
          }
          fileIo.writeSync(dest.fd, buf, { length: want });
          copied += want;
          onProgress({
            fileIndex: fileIndex, fileCount: fileCount, fileName: fileName,
            copiedBytes: copied, fileTotal: rawFd.length
          });
          // yield to the event loop: progress rendering + watchdog safety
          await new Promise<void>((resolve: () => void) => {
            setTimeout(() => {
              resolve();
            }, 0);
          });
        }
      } finally {
        try {
          fileIo.closeSync(dest);
        } catch (ignored) {
        }
      }
      // integrity check: destination size must match the packaged entry size
      const st2: fileIo.Stat = fileIo.statSync(destPath);
      if (st2.size !== rawFd.length) {
        fileIo.unlinkSync(destPath);
        throw new Error(`size mismatch after copy: ${destPath} ${st2.size} != ${rawFd.length}`);
      }
    } finally {
      try {
        rm.closeRawFdSync(rawPath);
      } catch (ignored) {
      }
    }
  }

  // Copy a flat set of packaged rawfile entries into destDir (created if
  // needed). Pre-checks every entry and returns false when the package does
  // not contain the full set, so callers can fall back to the HTTP path
  // without having touched the sandbox.
  async installRawDir(rawDir: string, fileNames: string[], destDir: string,
    onProgress: (p: RawCopyProgress) => void): Promise<boolean> {
    for (const name of fileNames) {
      if (!this.hasRawEntry(`${rawDir}/${name}`)) {
        hilog.warn(0x0000, TAG, 'rawfile entry missing: %{public}s/%{public}s', rawDir, name);
        return false;
      }
    }
    if (!fileIo.accessSync(destDir)) {
      fileIo.mkdirSync(destDir);
    }
    for (let i = 0; i < fileNames.length; i++) {
      const name: string = fileNames[i];
      await this.copyRawFile(`${rawDir}/${name}`, `${destDir}/${name}`, name,
        i + 1, fileNames.length, onProgress);
    }
    return true;
  }

  // Install the packaged album seed set (rawfile/album_seed: manifest.json +
  // jpgs) into destDir. Returns -1 when the package has no valid seed set,
  // otherwise the number of seed images ensured present in destDir. The
  // caller then runs its existing sandbox-seed index path over destDir.
  async installSeedSet(destDir: string, onProgress: (p: RawCopyProgress) => void): Promise<number> {
    let manifestRaw: string = '';
    try {
      const u8: Uint8Array =
        this.context.resourceManager.getRawFileContentSync('album_seed/manifest.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      manifestRaw = decoder.decodeToString(u8);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'packaged album_seed manifest missing');
      return -1;
    }
    let manifest: RawSeedManifest | null = null;
    try {
      manifest = JSON.parse(manifestRaw) as RawSeedManifest;
    } catch (e) {
      manifest = null;
    }
    if (manifest === null || !Array.isArray(manifest.files)) {
      hilog.error(0x0000, TAG, 'packaged manifest.json invalid');
      return -1;
    }
    const names: string[] = [];
    for (const name of manifest.files) {
      if (typeof name !== 'string' || name.length === 0 || name.indexOf('/') >= 0) {
        continue;
      }
      const lower: string = name.toLowerCase();
      if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg') && !lower.endsWith('.png')) {
        continue;
      }
      names.push(name);
    }
    if (names.length === 0) {
      return -1;
    }
    const ok: boolean = await this.installRawDir('album_seed', names, destDir, onProgress);
    return ok ? names.length : -1;
  }
}
