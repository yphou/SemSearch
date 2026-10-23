import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { dataSharePredicates } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { taskpool } from '@kit.ArkTS';
import { imgEmbedTask } from './EmbedTasks';
import { MnnGate } from './MnnGate';

// US2/US3: persistent photo index.
// - photo_meta.json  : PhotoRecord list (resume by status, incremental diff by id+dateModified)
// - photo_index.bin  : header {magic 'PSIX', u32 version, u32 count, u32 dim=768} + count x 768 float32,
//                      row order aligned with records where status === 'indexed'
// Vectors are re-written whole after each photo (small: 3 KB per photo) so a kill at any
// point loses at most one photo of work. Consistency rule: meta written first, vectors after.

export interface PhotoRecord {
  id: string; // photo library asset uri (stable identifier)
  uri: string;
  displayName: string;
  dateModified: number;
  status: string; // 'pending' | 'indexed' | 'failed'
}

interface PhotoMetaFile {
  version: number;
  records: PhotoRecord[];
  completedAt: number | null;
}

// US4: KMeans clustering output
export interface PhotoCluster {
  centroid: number[];
  photoIds: string[];
}

export interface ClusterResult {
  k: number;
  clusters: PhotoCluster[];
}

// deterministic Park-Miller LCG: cluster layout reproducible across runs
class Lcg {
  private state: number = 20261020 % 2147483647;
  next(): number {
    this.state = (this.state * 48271) % 2147483647;
    return this.state / 2147483647;
  }
}

function sqDist(a: Float32Array, b: Float32Array): number {
  let s: number = 0;
  for (let i = 0; i < a.length; i++) {
    const d: number = a[i] - b[i];
    s += d * d;
  }
  return s;
}

function minSqDist(p: Float32Array, centroids: Float32Array[]): number {
  let m: number = sqDist(p, centroids[0]);
  for (let c = 1; c < centroids.length; c++) {
    const d: number = sqDist(p, centroids[c]);
    if (d < m) {
      m = d;
    }
  }
  return m;
}

const INDEX_VERSION: number = 1;
const EMBED_DIM: number = 768;
const TAG: string = 'SemSearch';

export class PhotoIndexManager {
  private context: common.UIAbilityContext;
  private indexDir: string;
  private metaPath: string;
  private binPath: string;
  private meta: PhotoMetaFile = { version: INDEX_VERSION, records: [], completedAt: null };
  private vectors: Map<string, Float32Array> = new Map();
  private running: boolean = false;
  public totalCount: number = 0;
  public indexedCount: number = 0;
  public failedCount: number = 0;
  public pendingCount: number = 0;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.indexDir = context.filesDir + '/photoindex';
    this.metaPath = this.indexDir + '/photo_meta.json';
    this.binPath = this.indexDir + '/photo_index.bin';
    if (!fileIo.accessSync(this.indexDir)) {
      fileIo.mkdirSync(this.indexDir);
    }
    this.loadMeta();
    this.loadVectors();
    this.selfHeal();
    this.updateCounts();
  }

  // ------------------------------------------------------------- persistence

  private loadMeta(): void {
    if (!fileIo.accessSync(this.metaPath)) {
      this.meta = { version: INDEX_VERSION, records: [], completedAt: null };
      return;
    }
    try {
      const raw: string = fileIo.readTextSync(this.metaPath);
      const parsed: PhotoMetaFile = JSON.parse(raw) as PhotoMetaFile;
      if (parsed === null || parsed === undefined || !Array.isArray(parsed.records)) {
        this.meta = { version: INDEX_VERSION, records: [], completedAt: null };
        return;
      }
      const recs: PhotoRecord[] = [];
      for (const r of parsed.records) {
        if (typeof r.id === 'string' && typeof r.uri === 'string' && typeof r.displayName === 'string' &&
          typeof r.dateModified === 'number' && typeof r.status === 'string') {
          const status: string = (r.status === 'indexed' || r.status === 'failed') ? r.status : 'pending';
          recs.push({ id: r.id, uri: r.uri, displayName: r.displayName, dateModified: r.dateModified, status: status });
        }
      }
      const completedAt: number | null = typeof parsed.completedAt === 'number' ? parsed.completedAt : null;
      const version: number = typeof parsed.version === 'number' ? parsed.version : INDEX_VERSION;
      this.meta = { version: version, records: recs, completedAt: completedAt };
    } catch (e) {
      hilog.error(0x0000, TAG, 'loadMeta failed: %{public}s', `${e}`);
      this.meta = { version: INDEX_VERSION, records: [], completedAt: null };
    }
  }

  private saveMeta(): void {
    const json: string = JSON.stringify(this.meta);
    const file = fileIo.openSync(this.metaPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, json);
    fileIo.closeSync(file);
  }

  private loadVectors(): void {
    if (!fileIo.accessSync(this.binPath)) {
      return;
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(this.binPath);
      if (stat.size < 16) {
        return;
      }
      const ab: ArrayBuffer = new ArrayBuffer(stat.size);
      const file = fileIo.openSync(this.binPath, fileIo.OpenMode.READ_ONLY);
      fileIo.readSync(file.fd, ab);
      fileIo.closeSync(file);
      const dv: DataView = new DataView(ab);
      let magicOk: boolean = true;
      const magic: string = 'PSIX';
      for (let i = 0; i < 4; i++) {
        if (dv.getUint8(i) !== magic.charCodeAt(i)) {
          magicOk = false;
          break;
        }
      }
      if (!magicOk) {
        hilog.error(0x0000, TAG, 'photo_index.bin bad magic, ignoring');
        return;
      }
      const version: number = dv.getUint32(4, true);
      const count: number = dv.getUint32(8, true);
      const dim: number = dv.getUint32(12, true);
      if (version !== INDEX_VERSION || dim !== EMBED_DIM || 16 + count * dim * 4 > ab.byteLength) {
        hilog.error(0x0000, TAG, 'photo_index.bin bad header v=%{public}d count=%{public}d dim=%{public}d',
          version, count, dim);
        return;
      }
      // map vectors onto 'indexed' records in file order
      const indexed: PhotoRecord[] = this.meta.records.filter((r: PhotoRecord) => r.status === 'indexed');
      if (count !== indexed.length) {
        hilog.warn(0x0000, TAG, 'photo_index.bin count %{public}d != indexed %{public}d, discarding',
          count, indexed.length);
        return;
      }
      let offset: number = 16;
      for (let i = 0; i < indexed.length; i++) {
        const fa: Float32Array = new Float32Array(ab, offset, EMBED_DIM);
        const copy: Float32Array = new Float32Array(EMBED_DIM);
        copy.set(fa);
        this.vectors.set(indexed[i].id, copy);
        offset += EMBED_DIM * 4;
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'loadVectors failed: %{public}s', `${e}`);
    }
  }

  private saveVectors(): void {
    const indexed: PhotoRecord[] = [];
    for (const r of this.meta.records) {
      if (r.status === 'indexed' && this.vectors.has(r.id)) {
        indexed.push(r);
      }
    }
    const count: number = indexed.length;
    const ab: ArrayBuffer = new ArrayBuffer(16 + count * EMBED_DIM * 4);
    const dv: DataView = new DataView(ab);
    const magic: string = 'PSIX';
    for (let i = 0; i < 4; i++) {
      dv.setUint8(i, magic.charCodeAt(i));
    }
    dv.setUint32(4, INDEX_VERSION, true);
    dv.setUint32(8, count, true);
    dv.setUint32(12, EMBED_DIM, true);
    let offset: number = 16;
    for (const r of indexed) {
      const v: Float32Array = this.vectors.get(r.id) as Float32Array;
      const fa: Float32Array = new Float32Array(ab, offset, EMBED_DIM);
      fa.set(v);
      offset += EMBED_DIM * 4;
    }
    const file = fileIo.openSync(this.binPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, ab);
    fileIo.closeSync(file);
  }

  // an 'indexed' record without a matching vector (crash between the two writes) goes back to pending
  private selfHeal(): void {
    let changed: boolean = false;
    for (const r of this.meta.records) {
      if (r.status === 'indexed' && !this.vectors.has(r.id)) {
        r.status = 'pending';
        changed = true;
      }
    }
    if (changed) {
      this.saveMeta();
      this.saveVectors();
    }
  }

  private updateCounts(): void {
    let indexed: number = 0;
    let failed: number = 0;
    let pending: number = 0;
    for (const r of this.meta.records) {
      if (r.status === 'indexed') {
        indexed++;
      } else if (r.status === 'failed') {
        failed++;
      } else {
        pending++;
      }
    }
    this.indexedCount = indexed;
    this.failedCount = failed;
    this.pendingCount = pending;
    this.totalCount = this.meta.records.length;
  }

  // ------------------------------------------------------------- album access

  // public for Album.ets: reuse the asset list to fetch result thumbnails
  async listImageAssets(): Promise<photoAccessHelper.PhotoAsset[]> {
    const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.context);
    const predicates: dataSharePredicates.DataSharePredicates = new dataSharePredicates.DataSharePredicates();
    predicates.orderByDesc('date_added');
    const option: photoAccessHelper.FetchOptions = {
      fetchColumns: ['date_modified'],
      predicates: predicates
    };
    const result: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> = await helper.getAssets(option);
    const all: Array<photoAccessHelper.PhotoAsset> = await result.getAllObjects();
    return all.filter((a: photoAccessHelper.PhotoAsset) => a.photoType === photoAccessHelper.PhotoType.IMAGE);
  }

  private getDateModified(asset: photoAccessHelper.PhotoAsset): number {
    const v: photoAccessHelper.MemberType = asset.get(photoAccessHelper.PhotoKeys.DATE_MODIFIED);
    if (typeof v === 'number') {
      return v as number;
    }
    const parsed: number = Number(v);
    return isNaN(parsed) ? 0 : parsed;
  }

  // diff the album against the persisted index:
  // - indexed + same dateModified            -> keep (skip)
  // - new / changed / failed / still-pending  -> (re)index
  // - assets removed from album              -> drop record and vector
  // - imported records (non "file://media/" uri, e.g. sandbox seeds / picker copies)
  //   are never dropped by the album diff
  async syncFromAlbum(): Promise<void> {
    const assets: photoAccessHelper.PhotoAsset[] = await this.listImageAssets();
    const oldById: Map<string, PhotoRecord> = new Map();
    for (const r of this.meta.records) {
      oldById.set(r.id, r);
    }
    const seen: Set<string> = new Set();
    const newRecords: PhotoRecord[] = [];
    // imported records survive the album diff untouched
    for (const r of this.meta.records) {
      if (!r.id.startsWith('file://media/')) {
        newRecords.push(r);
      }
    }
    for (const asset of assets) {
      const id: string = asset.uri;
      const dm: number = this.getDateModified(asset);
      seen.add(id);
      const old: PhotoRecord | undefined = oldById.get(id);
      if (old !== undefined && old.status === 'indexed' && old.dateModified === dm) {
        newRecords.push(old);
      } else {
        this.vectors.delete(id);
        newRecords.push({ id: id, uri: asset.uri, displayName: asset.displayName, dateModified: dm, status: 'pending' });
      }
    }
    for (const r of this.meta.records) {
      if (!seen.has(r.id) && r.id.startsWith('file://media/')) {
        this.vectors.delete(r.id);
      }
    }
    this.meta.records = newRecords;
    this.meta.completedAt = null;
    this.saveMeta();
    this.saveVectors();
    this.updateCounts();
  }

  // Phase 14 (T039): Google Smart Album "Bulk select media" scope — keep only
  // the newest `count` media-library records (by dateModified) plus every
  // non-media import (sandbox seeds / picker copies), dropping the vectors of
  // anything trimmed. Already-indexed survivors keep their vectors so a
  // re-select at the same or larger number resumes incrementally.
  async syncFromAlbumRecent(count: number): Promise<void> {
    await this.syncFromAlbum();
    if (count <= 0 || this.meta.records.length <= count) {
      return;
    }
    // split media records (trimmable) from imports (always kept)
    const mediaRecs: PhotoRecord[] = [];
    const imports: PhotoRecord[] = [];
    for (const r of this.meta.records) {
      if (r.id.startsWith('file://media/')) {
        mediaRecs.push(r);
      } else {
        imports.push(r);
      }
    }
    const room: number = Math.max(0, count - imports.length);
    if (mediaRecs.length <= room) {
      return;
    }
    mediaRecs.sort((a: PhotoRecord, b: PhotoRecord): number => b.dateModified - a.dateModified);
    const keep: PhotoRecord[] = mediaRecs.slice(0, room);
    const keptIds: Set<string> = new Set<string>();
    for (const r of keep) {
      keptIds.add(r.id);
    }
    for (const r of mediaRecs) {
      if (!keptIds.has(r.id)) {
        this.vectors.delete(r.id);
      }
    }
    // preserve original relative order of the survivors for stable grids
    const newRecords: PhotoRecord[] = [];
    for (const r of this.meta.records) {
      if (!r.id.startsWith('file://media/') || keptIds.has(r.id)) {
        newRecords.push(r);
      }
    }
    this.meta.records = newRecords;
    this.saveMeta();
    this.saveVectors();
    this.updateCounts();
  }

  // Phase 14 (T043): public path for "Find similar images" — materialize a
  // readable sandbox copy of one record (media assets need a real file path
  // for the MNN imgEmbed task). Returns null for unknown ids.
  copyPhotoLocalForId(id: string): string | null {
    for (const r of this.meta.records) {
      if (r.id === id) {
        try {
          return this.copyPhotoToLocal(r);
        } catch (e) {
          hilog.error(0x0000, TAG, 'copyPhotoLocalForId failed: %{public}s', `${e}`);
          return null;
        }
      }
    }
    return null;
  }

  // copy a readable source (media-library uri, picker uri, or sandbox path) to dest
  private copyUriToFile(srcUri: string, dest: string): void {
    const src: fileIo.File = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
    try {
      const chunkSize: number = 256 * 1024;
      const chunks: ArrayBuffer[] = [];
      let total: number = 0;
      while (true) {
        const buf: ArrayBuffer = new ArrayBuffer(chunkSize);
        const n: number = fileIo.readSync(src.fd, buf);
        if (n <= 0) {
          break;
        }
        if (n < chunkSize) {
          const exact: ArrayBuffer = new ArrayBuffer(n);
          new Uint8Array(exact).set(new Uint8Array(buf, 0, n));
          chunks.push(exact);
          total += n;
          break;
        }
        chunks.push(buf);
        total += n;
      }
      if (total === 0) {
        throw new Error('empty photo file: ' + srcUri);
      }
      const dst: fileIo.File = fileIo.openSync(dest,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      for (const c of chunks) {
        fileIo.writeSync(dst.fd, c);
      }
      fileIo.closeSync(dst);
    } finally {
      fileIo.closeSync(src);
    }
  }

  // copy one photo library asset into the app sandbox (MNN imgEmbed needs a real file path)
  private copyPhotoToLocal(record: PhotoRecord): string {
    const destDir: string = this.context.cacheDir + '/indexing';
    if (!fileIo.accessSync(destDir)) {
      fileIo.mkdirSync(destDir);
    }
    const safeName: string = record.displayName.replace(/[/\\:*?"'`{}<>|[\]]/g, '_');
    const dest: string = destDir + '/' + safeName;
    this.copyUriToFile(record.uri, dest);
    return dest;
  }

  // ------------------------------------------------------------- import paths (T021 fallback)

  private hasRecord(id: string): boolean {
    for (const r of this.meta.records) {
      if (r.id === id) {
        return true;
      }
    }
    return false;
  }

  private addRecord(path: string, name: string, mtime: number): boolean {
    if (this.hasRecord(path)) {
      return false;
    }
    this.meta.records.push({ id: path, uri: path, displayName: name, dateModified: mtime, status: 'pending' });
    return true;
  }

  // import photos pushed into the app sandbox (filesDir/album_seed via `hdc file send`
  // after prepareDir made it shell-writable). Emulator L3 seeding path: media-library
  // push is not possible on the undebuggable image (root blocked, storage denied).
  async importFromSandbox(dirPath: string): Promise<number> {
    if (!fileIo.accessSync(dirPath)) {
      return 0;
    }
    const names: Array<string> = fileIo.listFileSync(dirPath);
    let added: number = 0;
    for (const name of names) {
      const lower: string = name.toLowerCase();
      if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg') && !lower.endsWith('.png')) {
        continue;
      }
      const p: string = dirPath + '/' + name;
      try {
        const st: fileIo.Stat = fileIo.statSync(p);
        if (st.isDirectory()) {
          continue;
        }
        if (this.addRecord(p, name, st.mtime)) {
          added++;
        }
      } catch (e) {
        hilog.error(0x0000, TAG, 'sandbox import stat failed for %{public}s: %{public}s', p, `${e}`);
      }
    }
    if (added > 0) {
      this.meta.completedAt = null;
      this.saveMeta();
      this.updateCounts();
    }
    return added;
  }

  // import photos picked through the system PhotoViewPicker (works without
  // READ_IMAGEVIDEO permission; each picked uri is copied into filesDir/imported
  // so later re-reads do not depend on the temporary picker authorization)
  async importPickedUris(uris: string[]): Promise<number> {
    const destDir: string = this.context.filesDir + '/imported';
    if (!fileIo.accessSync(destDir)) {
      fileIo.mkdirSync(destDir);
    }
    let added: number = 0;
    for (const uri of uris) {
      try {
        let name: string = uri.substring(uri.lastIndexOf('/') + 1);
        if (name.length === 0 || name.indexOf('.') < 0) {
          name = `picked_${Date.now()}_${added}.jpg`;
        }
        const dest: string = destDir + '/' + name;
        this.copyUriToFile(uri, dest);
        const st: fileIo.Stat = fileIo.statSync(dest);
        if (this.addRecord(dest, name, st.mtime)) {
          added++;
        }
      } catch (e) {
        hilog.error(0x0000, TAG, 'picker import failed for %{public}s: %{public}s', uri, `${e}`);
      }
    }
    if (added > 0) {
      this.meta.completedAt = null;
      this.saveMeta();
      this.updateCounts();
    }
    return added;
  }

  isRunning(): boolean {
    return this.running;
  }

  stopIndexing(): void {
    this.running = false;
  }

  // index exactly one pending record. Returns false when nothing is pending.
  // Called repeatedly from indexPending so each photo yields to the UI thread afterwards.
  // The imgEmbed NAPI call (22-65s per image on the x86 emulator) runs inside a
  // taskpool worker (see EmbedTasks.ets) so the UI thread never blocks on it.
  private async indexOne(): Promise<boolean> {
    let idx: number = -1;
    for (let i = 0; i < this.meta.records.length; i++) {
      if (this.meta.records[i].status === 'pending') {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      return false;
    }
    const record: PhotoRecord = this.meta.records[idx];
    const sw: number = Date.now();
    try {
      const localPath: string = this.copyPhotoToLocal(record);
      // hold the process-wide MNN gate across the whole native imgEmbed so
      // main-thread embed()/embedDoc() on either page and taskpool tasks
      // never run a concurrent forward on the shared session (MnnGate.ets)
      let vec: Float32Array = new Float32Array(0);
      await MnnGate.acquire();
      try {
        vec = await taskpool.execute(imgEmbedTask, localPath) as Float32Array;
      } finally {
        MnnGate.release();
      }
      if (vec.length !== EMBED_DIM) {
        throw new Error('unexpected dim ' + vec.length);
      }
      this.vectors.set(record.id, vec);
      record.status = 'indexed';
      hilog.info(0x0000, TAG, 'indexed %{public}s in %{public}d ms', record.displayName, Date.now() - sw);
    } catch (e) {
      record.status = 'failed';
      hilog.error(0x0000, TAG, 'index failed for %{public}s: %{public}s', record.displayName, `${e}`);
    }
    // consistency rule: meta first, then vector file
    this.updateCounts();
    this.saveMeta();
    this.saveVectors();
    return true;
  }

  // NOTE: cross-caller MNN serialization lives in MnnGate.ets (process-wide
  // gate). The former instance-level pause gate was removed: indexOne holds
  // the gate during each photo encode, and any embed()/initVisual() caller
  // that needs the engine simply queues behind it (FIFO).

  // background-ish indexing loop: one photo per macrotask, yields between photos
  // so the UI can update progress and stays usable between encodes.
  async indexPending(onProgress: (processed: number, total: number, name: string) => void): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    try {
      let processed: number = 0;
      const total: number = this.totalCount;
      onProgress(processed, total, '');
      while (this.running) {
        const name: string = this.nextPendingName();
        const did: boolean = await this.indexOne();
        if (!did) {
          break;
        }
        processed++;
        onProgress(processed, this.totalCount, name);
        if (this.pendingCount === 0) {
          break;
        }
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 50);
        });
      }
      if (this.pendingCount === 0) {
        this.meta.completedAt = Date.now();
        this.saveMeta();
      }
    } finally {
      this.running = false;
    }
  }

  private nextPendingName(): string {
    for (const r of this.meta.records) {
      if (r.status === 'pending') {
        return r.displayName;
      }
    }
    return '';
  }

  // ------------------------------------------------------------- search API (US3)

  getRecords(): PhotoRecord[] {
    return this.meta.records;
  }

  getVector(id: string): Float32Array | undefined {
    return this.vectors.get(id);
  }

  isReady(): boolean {
    return this.indexedCount > 0;
  }

  // ------------------------------------------------------------- clustering (US4)

  // On-device KMeans over the indexed photo embeddings.
  // - vectors L2-normalized, Euclidean distance (= monotone in cosine on normalized data)
  // - k-means++ seeding (deterministic LCG), Lloyd iterations
  // - stop after 30 rounds or when every centroid moves < 1e-4 (L2)
  // - kRequest <= 0 -> auto K = min(ceil(sqrt(N/2)), 12)
  cluster(kRequest: number): ClusterResult {
    const ids: string[] = [];
    const vecs: Float32Array[] = [];
    for (const r of this.meta.records) {
      if (r.status !== 'indexed') {
        continue;
      }
      const v: Float32Array | undefined = this.vectors.get(r.id);
      if (v === undefined) {
        continue;
      }
      const nrm: Float32Array = new Float32Array(EMBED_DIM);
      let norm: number = 0;
      for (let i = 0; i < EMBED_DIM; i++) {
        norm += v[i] * v[i];
      }
      norm = Math.sqrt(norm);
      if (norm > 0) {
        for (let i = 0; i < EMBED_DIM; i++) {
          nrm[i] = v[i] / norm;
        }
      }
      ids.push(r.id);
      vecs.push(nrm);
    }
    const n: number = ids.length;
    if (n === 0) {
      return { k: 0, clusters: [] };
    }
    let k: number = kRequest > 0 ? kRequest : Math.min(Math.ceil(Math.sqrt(n / 2)), 12);
    k = Math.max(1, Math.min(k, n));
    const rng: Lcg = new Lcg();

    // ---- k-means++ seeding
    const centroids: Float32Array[] = [];
    const firstIdx: number = Math.min(Math.floor(rng.next() * n), n - 1);
    centroids.push(vecs[firstIdx]);
    while (centroids.length < k) {
      const d2: number[] = [];
      let total: number = 0;
      for (let i = 0; i < n; i++) {
        const d: number = minSqDist(vecs[i], centroids);
        d2.push(d);
        total += d;
      }
      let next: number = -1;
      if (total > 0) {
        let pick: number = rng.next() * total;
        for (let i = 0; i < n; i++) {
          pick -= d2[i];
          if (pick <= 0) {
            next = i;
            break;
          }
        }
      }
      if (next < 0) {
        // degenerate (all remaining points identical to a centroid): take next index
        next = Math.min(centroids.length, n - 1);
      }
      centroids.push(vecs[next]);
    }

    // ---- Lloyd iterations
    const assign: number[] = [];
    for (let i = 0; i < n; i++) {
      assign.push(0);
    }
    for (let round: number = 0; round < 30; round++) {
      let changed: number = 0;
      for (let i = 0; i < n; i++) {
        let best: number = 0;
        let bestD: number = sqDist(vecs[i], centroids[0]);
        for (let c = 1; c < k; c++) {
          const d: number = sqDist(vecs[i], centroids[c]);
          if (d < bestD) {
            bestD = d;
            best = c;
          }
        }
        if (assign[i] !== best) {
          changed++;
          assign[i] = best;
        }
      }
      if (changed === 0 && round > 0) {
        break;
      }
      let maxMove: number = 0;
      for (let c = 0; c < k; c++) {
        const sum: number[] = [];
        for (let j = 0; j < EMBED_DIM; j++) {
          sum.push(0);
        }
        let cnt: number = 0;
        for (let i = 0; i < n; i++) {
          if (assign[i] === c) {
            cnt++;
            for (let j = 0; j < EMBED_DIM; j++) {
              sum[j] += vecs[i][j];
            }
          }
        }
        if (cnt === 0) {
          continue; // empty cluster keeps its centroid; points may rejoin next round
        }
        const nc: Float32Array = new Float32Array(EMBED_DIM);
        for (let j = 0; j < EMBED_DIM; j++) {
          nc[j] = sum[j] / cnt;
        }
        const mv: number = sqDist(nc, centroids[c]);
        if (mv > maxMove) {
          maxMove = mv;
        }
        centroids[c] = nc;
      }
      if (Math.sqrt(maxMove) < 1e-4) {
        break;
      }
    }

    // ---- assemble result (drop empty clusters)
    const out: PhotoCluster[] = [];
    for (let c = 0; c < k; c++) {
      const centroid: number[] = [];
      for (let j = 0; j < EMBED_DIM; j++) {
        centroid.push(centroids[c][j]);
      }
      const photoIds: string[] = [];
      for (let i = 0; i < n; i++) {
        if (assign[i] === c) {
          photoIds.push(ids[i]);
        }
      }
      if (photoIds.length > 0) {
        out.push({ centroid: centroid, photoIds: photoIds });
      }
    }
    return { k: out.length, clusters: out };
  }
}
