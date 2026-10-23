// SemSearch (Phase 14, T041-T043): Google AI Edge Gallery Smart Album replica.
// Engine (D1 / MNN 70-token) is carried over unchanged; the UI copies the
// Google Smart Album structure observed on the reference device (T038):
//   landing  : welcome title/description, two PhotoStack cards (sample +
//              user photos, 168dp rotated stack cards + count badge), docked
//              "Search photos…" pill, access dialog ("Start analyzing media?"),
//              bulk-select bottom sheet (count input + slider), indexing progress
//   search   : back + query input ("Search for term…"), lazy 3-column grid
//              (library = Analyzed/Analyzing… tiles; results = score "0.72"
//              tiles), indexing warning banner, empty states, per-tile detail
//   detail   : large photo, "N% match" badge, "Find similar images" pill
//              (imgEmbedTask + cosine, excludes itself), expandable embedding info
//   cluster  : KMeans groups (K slider, auto K), group grid + member list
// Strings are verbatim from Google strings.xml (smartalbum_*).
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { taskpool } from '@kit.ArkTS';
import { isLoaded, embed, prepareDir } from 'libentry.so';
import { visualInitTask, imgEmbedTask } from '../common/EmbedTasks';
import { MnnGate } from '../common/MnnGate';
import { RawInstaller, RawCopyProgress } from '../common/RawInstaller';
import { PhotoIndexManager, ClusterResult, PhotoCluster } from '../common/PhotoIndexManager';
import { thumbCache } from '../common/ThumbCache';

const TAG: string = 'SemSearch';

// Google SmartAlbumScreen.kt STACK_ANGLES / STACK_OFFSETS (dp)
const STACK_ANGLES: number[] = [0, 4, 8, 12, 7, 2, -3, -8, -12, -7, -2, 3];
const STACK_OFFSETS_X: number[] = [0, 9, -9, 11, -8, 7, -11, 9, -9, 8, -7, 10];
const STACK_OFFSETS_Y: number[] = [0, -7, -5, 6, 8, -9, -7, 8, 6, -8, -9, 7];
const PLACEHOLDER_SEQ: number[] = [2, 1, 0];

function stackAngle(seq: number): number {
  return STACK_ANGLES[seq % STACK_ANGLES.length];
}

function stackOffsetX(seq: number): number {
  return STACK_OFFSETS_X[seq % STACK_OFFSETS_X.length];
}

function stackOffsetY(seq: number): number {
  return STACK_OFFSETS_Y[seq % STACK_OFFSETS_Y.length];
}

function cosSim(a: Float32Array, b: Float32Array): number {
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na === 0 || nb === 0) {
    return 0;
  }
  return dot / Math.sqrt(na * nb);
}

// grid item for both the library grid (score < 0) and the results grid
interface AlbumResultItem {
  id: string;
  displayName: string;
  score: number; // cosine similarity; -1 for library tiles
  indexed: boolean;
}

interface ClusterGroupItem {
  clusterIndex: number;
  count: number;
  repId: string;
}

interface GroupMemberItem {
  id: string;
  displayName: string;
}

// IDataSource for Grid+LazyForEach (1600+ records scroll smoothly)
class AlbumGridSource implements IDataSource {
  private items: AlbumResultItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): AlbumResultItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((l: DataChangeListener): boolean => l !== listener);
  }

  setItems(items: AlbumResultItem[]): void {
    this.items = items;
    this.notifyReload();
  }

  // flip indexed flags for ids that finished encoding (indexing progress ticks)
  markIndexed(ids: Set<string>): void {
    for (let i = 0; i < this.items.length; i++) {
      if (ids.has(this.items[i].id) && !this.items[i].indexed) {
        this.items[i].indexed = true;
        this.notifyChange(i);
      }
    }
  }

  private notifyReload(): void {
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }

  private notifyChange(index: number): void {
    for (const l of this.listeners) {
      l.onDataChange(index);
    }
  }
}

// ------------------------------------------------------------- child components

// One photo tile: square (aspectRatio 1), bottom black gradient overlay and
// a white bold 11fp label — "Analyzed"/"Analyzing…" (library, bottomStart) or
// the similarity score "0.72" (results, bottomEnd). Google PhotoGridTile /
// BackgroundAssetGridTile replica.
@Component
struct AlbumGridCell {
  @Prop @Watch('onCellIdChange') cellId: string = '';
  @Prop cellScore: number = -1;
  @Prop cellIndexed: boolean = true;
  @Prop cellLibrary: boolean = false;
  @State cellThumb: image.PixelMap | null = null;
  onOpen: (id: string) => void = (id: string) => {
  };

  aboutToAppear(): void {
    this.loadThumb();
  }

  onCellIdChange(): void {
    this.cellThumb = null;
    this.loadThumb();
  }

  private async loadThumb(): Promise<void> {
    if (this.cellId.length === 0) {
      return;
    }
    const pm: image.PixelMap | null = await thumbCache.get(this.cellId);
    if (pm !== null) {
      this.cellThumb = pm;
    }
  }

  build() {
    Stack() {
      if (this.cellThumb !== null) {
        Image(this.cellThumb)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.cellLibrary && !this.cellIndexed ? 0.75 : 1)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.m3_surface_container_highest'))
      }
      // bottom fade-to-black overlay (Google tile gradient)
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 180, colors: [['#00000000', 0.45], ['#CC000000', 1]] })
      Row() {
        if (this.cellLibrary) {
          Text(this.cellIndexed ? 'Analyzed' : 'Analyzing…')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
        }
        Blank()
        if (!this.cellLibrary && this.cellScore >= 0) {
          Text(this.cellScore.toFixed(2))
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: 8, right: 8, bottom: 6 })
    }
    .aspectRatio(1)
    .borderRadius(8)
    .clip(true)
    .onClick(() => {
      this.onOpen(this.cellId);
    })
  }
}

// One 168dp stack card from the landing photo stacks (Google PhotoStackCard):
// surface card radius 14 + shadow, 4dp inset photo area radius 10, rotation
// and offset driven by the card sequence index.
@Component
struct AlbumStackCard {
  @Prop @Watch('onCardIdChange') cardId: string = '';
  @Prop cardSeq: number = 0;
  @Prop cardIsAdd: boolean = false; // "Add photos" placeholder variant
  @State cardThumb: image.PixelMap | null = null;

  aboutToAppear(): void {
    this.loadThumb();
  }

  onCardIdChange(): void {
    this.cardThumb = null;
    this.loadThumb();
  }

  private async loadThumb(): Promise<void> {
    if (this.cardId.length === 0) {
      return;
    }
    const pm: image.PixelMap | null = await thumbCache.get(this.cardId);
    if (pm !== null) {
      this.cardThumb = pm;
    }
  }

  build() {
    Column() {
      if (this.cardThumb !== null) {
        Image(this.cardThumb)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else if (this.cardId.length === 0) {
        SymbolGlyph(this.cardIsAdd ? $r('sys.symbol.plus') : $r('sys.symbol.ohos_photo'))
          .fontSize(48)
          .fontColor([this.cardIsAdd ? $r('app.color.m3_primary') : $r('app.color.m3_on_surface_variant')])
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(10)
    .clip(true)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.cardId.length === 0 && this.cardIsAdd ?
      $r('app.color.m3_primary_container') : $r('app.color.m3_surface_container_highest'))
    .padding(4)
    .width(168)
    .height(168)
    .borderRadius(14)
    .backgroundColor($r('app.color.m3_surface'))
    .shadow({ radius: 8, color: '#33000000', offsetY: 2 })
    .rotate({ angle: stackAngle(this.cardSeq) })
    .offset({ x: stackOffsetX(this.cardSeq), y: stackOffsetY(this.cardSeq) })
  }
}

// cluster member row: 56dp thumb (via thumbCache) + display name
@Component
struct AlbumMemberRow {
  @Prop @Watch('onRowIdChange') rowId: string = '';
  @Prop rowName: string = '';
  @State rowThumb: image.PixelMap | null = null;

  aboutToAppear(): void {
    this.loadThumb();
  }

  onRowIdChange(): void {
    this.rowThumb = null;
    this.loadThumb();
  }

  private async loadThumb(): Promise<void> {
    if (this.rowId.length === 0) {
      return;
    }
    const pm: image.PixelMap | null = await thumbCache.get(this.rowId);
    if (pm !== null) {
      this.rowThumb = pm;
    }
  }

  build() {
    Row({ space: 12 }) {
      if (this.rowThumb !== null) {
        Image(this.rowThumb)
          .width(56)
          .height(56)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width(56)
          .height(56)
          .borderRadius(8)
          .backgroundColor($r('app.color.m3_surface_container_highest'))
      }
      Text(this.rowName)
        .fontSize(14)
        .fontColor($r('app.color.m3_on_surface'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .padding(8)
    .borderRadius(12)
    .backgroundColor($r('app.color.m3_surface_container'))
    .width('100%')
  }
}

// ------------------------------------------------------------- page

@Entry
@Component
struct Album {
  @State pageState: string = 'init'; // init | ready | nomodel
  @State viewName: string = 'landing'; // landing | search | cluster
  @State hasPermission: boolean = false;
  // counts
  @State indexedCount: number = 0;
  @State totalCount: number = 0;
  @State failedCount: number = 0;
  @State pendingCount: number = 0;
  @State userCount: number = 0;
  @State userIndexed: number = 0;
  @State sampleCount: number = 0;
  @State sampleIndexed: number = 0;
  @State userStackIds: string[] = [];
  @State sampleStackIds: string[] = [];
  // indexing
  @State indexing: boolean = false;
  @State progressProcessed: number = 0;
  @State progressTotal: number = 0;
  // search
  @State query: string = '';
  @State searching: boolean = false;
  @State gridMode: string = 'library'; // library | results
  @State similarMode: boolean = false;
  @State resultCount: number = 0;
  @State bannerDismissed: boolean = false;
  // access dialog + bulk sheet
  @State showAccessDialog: boolean = false;
  @State showBulkSheet: boolean = false;
  @State bulkCount: string = '0';
  @State bulkMax: number = 0;
  // import
  @State importing: boolean = false;
  @State note: string = '';
  // detail overlay
  @State showDetail: boolean = false;
  @State detailId: string = '';
  @State detailName: string = '';
  @State detailScore: number = -1;
  @State detailIndexed: boolean = true;
  @State detailThumb: image.PixelMap | null = null;
  @State detailFinding: boolean = false;
  @State showDetailInfo: boolean = false;
  // cluster
  @State clustering: boolean = false;
  @State kSetting: number = 0; // 0 = auto
  @State clusterGroups: ClusterGroupItem[] = [];
  @State viewingGroup: number = -1;
  @State groupMembers: GroupMemberItem[] = [];
  @State clusterNote: string = '';

  private context: common.UIAbilityContext | null = null;
  private manager: PhotoIndexManager | null = null;
  private clusterResult: ClusterResult | null = null;
  private gridSource: AlbumGridSource = new AlbumGridSource();
  private searchTimer: number = -1;
  private assetsByUri: Map<string, photoAccessHelper.PhotoAsset> = new Map();
  private assetsLoaded: boolean = false;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const ctx: common.UIAbilityContext = this.context;
    // 0777 on files/ and files/album_seed so external tooling can push seeds
    prepareDir(ctx.filesDir);
    prepareDir(ctx.filesDir + '/album_seed');
    this.bootstrap();
  }

  // Leaving the page stops the indexing loop after the in-flight photo;
  // re-entering resumes pending work (bootstrap -> runIndexing).
  aboutToDisappear(): void {
    const m: PhotoIndexManager | null = this.manager;
    if (m !== null) {
      m.stopIndexing();
    }
  }

  // Engine load runs in a taskpool worker (visualInitTask) behind the
  // process-wide MNN gate — never on the UI thread (watchdog kill risk).
  // No auto permission request / album sync here: the Google flow asks for
  // access on the user stack card, and the bulk-select scope is preserved.
  private async bootstrap(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context as common.UIAbilityContext;
    const modelDir: string = ctx.filesDir + '/model';
    if (!fileIo.accessSync(modelDir + '/config.json')) {
      this.pageState = 'nomodel';
      return;
    }
    if (!isLoaded()) {
      try {
        await MnnGate.acquire();
        let ok: boolean = false;
        try {
          ok = await taskpool.execute(visualInitTask, modelDir) as boolean;
        } finally {
          MnnGate.release();
        }
        if (!ok) {
          this.pageState = 'nomodel';
          return;
        }
      } catch (e) {
        hilog.error(0x0000, TAG, 'visual init task failed: %{public}s', `${e}`);
        this.pageState = 'nomodel';
        return;
      }
    }
    this.manager = new PhotoIndexManager(ctx);
    this.registerThumbLoader();
    this.refreshCounts();
    this.computeStacks();
    this.pageState = 'ready';
    // permission probe: the asset query throws without READ_IMAGEVIDEO
    try {
      await this.loadAssetMap();
      this.hasPermission = true;
    } catch (e) {
      this.hasPermission = false;
    }
    // resume pending encodes (breakpoint continuation), never re-sync here
    if (this.pendingCount > 0) {
      this.runIndexing();
    }
  }

  private refreshCounts(): void {
    const mgr: PhotoIndexManager | null = this.manager;
    if (mgr === null) {
      return;
    }
    this.indexedCount = mgr.indexedCount;
    this.totalCount = mgr.totalCount;
    this.failedCount = mgr.failedCount;
    this.pendingCount = mgr.pendingCount;
  }

  // split records into the sample seed stack ("/album_seed/" paths) and the
  // user stack (media assets + picker imports); show up to 12 recent ids
  private computeStacks(): void {
    const mgr: PhotoIndexManager | null = this.manager;
    if (mgr === null) {
      return;
    }
    const userIds: string[] = [];
    const sampleIds: string[] = [];
    let userCount = 0;
    let userIndexed = 0;
    let sampleCount = 0;
    let sampleIndexed = 0;
    for (const r of mgr.getRecords()) {
      const isSeed: boolean = r.id.indexOf('/album_seed/') >= 0;
      if (isSeed) {
        sampleCount++;
        if (r.status === 'indexed') {
          sampleIndexed++;
        }
        if (sampleIds.length < 12 && r.status !== 'failed') {
          sampleIds.push(r.id);
        }
      } else if (r.status !== 'failed') {
        userCount++;
        if (r.status === 'indexed') {
          userIndexed++;
        }
        if (userIds.length < 12) {
          userIds.push(r.id);
        }
      }
    }
    this.userStackIds = userIds;
    this.sampleStackIds = sampleIds;
    this.userCount = userCount;
    this.userIndexed = userIndexed;
    this.sampleCount = sampleCount;
    this.sampleIndexed = sampleIndexed;
  }

  private async loadAssetMap(): Promise<void> {
    const mgr: PhotoIndexManager = this.manager as PhotoIndexManager;
    const assets: photoAccessHelper.PhotoAsset[] = await mgr.listImageAssets();
    const map: Map<string, photoAccessHelper.PhotoAsset> = new Map();
    for (const a of assets) {
      map.set(a.uri, a);
    }
    this.assetsByUri = map;
    this.assetsLoaded = true;
  }

  // 144px thumbnails: media assets via PhotoAsset.getThumbnail, sandbox
  // files (seeds / picker imports) via ImageSource — all through ThumbCache
  private registerThumbLoader(): void {
    thumbCache.setLoader(async (id: string): Promise<image.PixelMap | null> => {
      if (id.startsWith('file://media/')) {
        let asset: photoAccessHelper.PhotoAsset | undefined = this.assetsByUri.get(id);
        if (asset === undefined) {
          if (!this.assetsLoaded) {
            await this.loadAssetMap();
            asset = this.assetsByUri.get(id);
          }
          if (asset === undefined) {
            return null;
          }
        }
        return await asset.getThumbnail({ width: 144, height: 144 });
      }
      const src: image.ImageSource = image.createImageSource(id);
      try {
        return await src.createPixelMap({ desiredSize: { width: 144, height: 144 } });
      } finally {
        src.release();
      }
    });
  }

  private async requestPermission(): Promise<boolean> {
    const ctx: common.UIAbilityContext = this.context as common.UIAbilityContext;
    const atm: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    try {
      const result = await atm.requestPermissionsFromUser(ctx, ['ohos.permission.READ_IMAGEVIDEO']);
      const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
      return granted;
    } catch (e) {
      hilog.error(0x0000, TAG, 'request permission failed: %{public}s', `${e}`);
      return false;
    }
  }

  // ---------------- landing flows (Google SmartAlbumScreen)

  private async onUserStackClick(): Promise<void> {
    if (this.hasPermission && this.userCount > 0) {
      this.openSearchView();
      return;
    }
    if (!this.hasPermission) {
      const granted: boolean = await this.requestPermission();
      if (granted) {
        this.hasPermission = true;
        try {
          await this.loadAssetMap();
        } catch (e) {
          hilog.error(0x0000, TAG, 'load assets after grant failed: %{public}s', `${e}`);
        }
        this.showAccessDialog = true;
      } else {
        this.note = 'Photo library access denied. "Select media" still works without it.';
      }
      return;
    }
    // permission granted but no photos indexed yet
    this.showAccessDialog = true;
  }

  private async onSampleStackClick(): Promise<void> {
    if (this.sampleCount === 0) {
      await this.importFromPackage();
    }
    this.openSearchView();
  }

  // access dialog: "Select media" -> system PhotoViewPicker import
  private async onSelectMedia(): Promise<void> {
    this.showAccessDialog = false;
    const added: number = await this.pickAndImport();
    if (added > 0) {
      this.openSearchView();
    }
  }

  // access dialog: "Bulk select media" -> bulk bottom sheet
  private async onBulkSelect(): Promise<void> {
    this.showAccessDialog = false;
    if (!this.hasPermission) {
      const granted: boolean = await this.requestPermission();
      if (!granted) {
        this.note = 'Photo library access denied. "Select media" still works without it.';
        return;
      }
      this.hasPermission = true;
    }
    try {
      await this.loadAssetMap();
    } catch (e) {
      hilog.error(0x0000, TAG, 'load assets for bulk failed: %{public}s', `${e}`);
      this.note = `Could not read the photo library: ${e}`;
      return;
    }
    this.bulkMax = this.assetsByUri.size;
    this.bulkCount = '0';
    this.showBulkSheet = true;
  }

  private bulkNum(): number {
    const parsed: number = parseInt(this.bulkCount);
    if (isNaN(parsed) || parsed < 0) {
      return 0;
    }
    return Math.min(parsed, this.bulkMax);
  }

  // bulk sheet confirm: syncFromAlbumRecent(count) keeps the newest `count`
  // media records plus every import, then encodes what is pending
  private async onBulkConfirm(): Promise<void> {
    const n: number = this.bulkNum();
    if (n <= 0) {
      return;
    }
    this.showBulkSheet = false;
    const mgr: PhotoIndexManager = this.manager as PhotoIndexManager;
    try {
      await mgr.syncFromAlbumRecent(n);
    } catch (e) {
      hilog.error(0x0000, TAG, 'bulk sync failed: %{public}s', `${e}`);
      this.note = `Bulk select failed: ${e}`;
      return;
    }
    this.refreshCounts();
    this.computeStacks();
    this.runIndexing();
  }

  // ---------------- imports

  private async pickAndImport(): Promise<number> {
    if (this.importing) {
      return 0;
    }
    const ctx: common.UIAbilityContext = this.context as common.UIAbilityContext;
    this.importing = true;
    let added: number = 0;
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const opt: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      opt.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      opt.maxSelectNumber = 20;
      const res: photoAccessHelper.PhotoSelectResult = await picker.select(opt);
      if (res.photoUris.length > 0) {
        if (this.manager === null) {
          this.manager = new PhotoIndexManager(ctx);
        }
        added = await (this.manager as PhotoIndexManager).importPickedUris(res.photoUris);
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'picker import failed: %{public}s', `${e}`);
      this.note = `Import failed: ${e}`;
    }
    this.importing = false;
    if (added > 0) {
      this.refreshCounts();
      this.computeStacks();
      this.runIndexing();
    }
    return added;
  }

  // sample photos: stream rawfile/album_seed out of the package (offline
  // first), then hand the directory to the sandbox import path
  private async importFromPackage(): Promise<void> {
    if (this.importing) {
      return;
    }
    const ctx: common.UIAbilityContext = this.context as common.UIAbilityContext;
    this.importing = true;
    this.note = 'Importing sample photos…';
    try {
      const installer: RawInstaller = new RawInstaller(ctx);
      const destDir: string = ctx.filesDir + '/album_seed';
      const ensured: number = await installer.installSeedSet(destDir,
        (p: RawCopyProgress) => {
          this.note = `Importing sample photos ${p.fileIndex}/${p.fileCount}`;
        });
      if (ensured < 0) {
        this.note = 'Sample photos missing from package';
        this.importing = false;
        return;
      }
      if (this.manager === null) {
        this.manager = new PhotoIndexManager(ctx);
      }
      const added: number = await (this.manager as PhotoIndexManager).importFromSandbox(destDir);
      this.note = added > 0 ? `Imported ${ensured} sample photos` : '';
      hilog.info(0x0000, TAG, 'sample seed import: %{public}d ensured, %{public}d added', ensured, added);
      if (added > 0) {
        this.refreshCounts();
        this.computeStacks();
        this.runIndexing();
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'sample import failed: %{public}s', `${e}`);
      this.note = `Sample import failed: ${e}`;
    }
    this.importing = false;
  }

  // ---------------- indexing (resume pending; no album sync)

  private async runIndexing(): Promise<void> {
    const mgr: PhotoIndexManager | null = this.manager;
    if (mgr === null || this.indexing) {
      return;
    }
    this.indexing = true;
    try {
      await mgr.indexPending((processed: number, total: number, name: string) => {
        this.progressProcessed = processed;
        this.progressTotal = total;
        this.refreshCounts();
        this.computeStacks();
        if (this.viewName === 'search' && this.gridMode === 'library') {
          const ids: Set<string> = new Set<string>();
          for (const r of mgr.getRecords()) {
            if (r.status === 'indexed') {
              ids.add(r.id);
            }
          }
          this.gridSource.markIndexed(ids);
        }
      });
    } catch (e) {
      hilog.error(0x0000, TAG, 'indexing failed: %{public}s', `${e}`);
    }
    this.indexing = false;
    this.refreshCounts();
    this.computeStacks();
  }

  private progressPct(): number {
    if (this.progressTotal <= 0) {
      return 0;
    }
    return Math.min(100, Math.round(this.progressProcessed / this.progressTotal * 100));
  }

  // ---------------- search view

  private openSearchView(): void {
    this.viewName = 'search';
    this.similarMode = false;
    this.query = '';
    this.showLibraryGrid();
  }

  private exitSearchView(): void {
    this.viewName = 'landing';
    this.query = '';
    this.similarMode = false;
    this.showLibraryGrid();
  }

  private showLibraryGrid(): void {
    this.gridMode = 'library';
    this.resultCount = 0;
    const mgr: PhotoIndexManager | null = this.manager;
    const items: AlbumResultItem[] = [];
    if (mgr !== null) {
      for (const r of mgr.getRecords()) {
        if (r.status === 'failed') {
          continue;
        }
        items.push({ id: r.id, displayName: r.displayName, score: -1, indexed: r.status === 'indexed' });
      }
    }
    this.resultCount = items.length;
    this.gridSource.setItems(items);
  }

  private onQueryChange(v: string): void {
    this.query = v;
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
    }
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.runSearch();
    }, 300);
  }

  private clearQuery(): void {
    this.query = '';
    if (this.gridMode !== 'library') {
      this.similarMode = false;
      this.showLibraryGrid();
    }
  }

  private runSearch(): void {
    const q: string = this.query.trim();
    if (q.length === 0) {
      // similar results own the empty-query screen (Google cancels the
      // pending search job in searchSimilarImages before clearing the text)
      if (this.gridMode !== 'library' && !this.similarMode) {
        this.similarMode = false;
        this.showLibraryGrid();
      }
      return;
    }
    const mgr: PhotoIndexManager | null = this.manager;
    if (mgr === null || mgr.indexedCount === 0) {
      // nothing analyzed yet -> "No matching media found" empty state
      this.gridMode = 'results';
      this.similarMode = false;
      this.resultCount = 0;
      this.gridSource.setItems([]);
      return;
    }
    if (this.searching) {
      return;
    }
    this.searching = true;
    this.performSearchAsync(q);
  }

  // text-to-photo: embed the query behind the MNN gate, rank every indexed
  // photo by cosine similarity, show the top 100 (Google caps the grid too)
  private async performSearchAsync(q: string): Promise<void> {
    try {
      const mgr: PhotoIndexManager = this.manager as PhotoIndexManager;
      await MnnGate.acquire();
      let qvec: Float32Array = new Float32Array(0);
      try {
        qvec = embed(q);
      } finally {
        MnnGate.release();
      }
      const items: AlbumResultItem[] = [];
      for (const r of mgr.getRecords()) {
        if (r.status !== 'indexed') {
          continue;
        }
        const v: Float32Array | undefined = mgr.getVector(r.id);
        if (v === undefined) {
          continue;
        }
        items.push({ id: r.id, displayName: r.displayName, score: cosSim(qvec, v), indexed: true });
      }
      items.sort((a: AlbumResultItem, b: AlbumResultItem) => b.score - a.score);
      const top: AlbumResultItem[] = items.slice(0, Math.min(items.length, 100));
      this.gridMode = 'results';
      this.similarMode = false;
      this.resultCount = top.length;
      this.gridSource.setItems(top);
      hilog.info(0x0000, TAG, 'search "%{public}s": %{public}d matches, %{public}d shown',
        q, items.length, top.length);
    } catch (e) {
      hilog.error(0x0000, TAG, 'search failed: %{public}s', `${e}`);
      this.gridMode = 'results';
      this.resultCount = 0;
      this.gridSource.setItems([]);
    }
    this.searching = false;
  }

  private searchHeaderTitle(): string {
    if (this.gridMode === 'results') {
      if (this.similarMode) {
        return 'Similar photos';
      }
      const n: number = this.resultCount;
      return `${n} ${n === 1 ? 'result' : 'results'}`;
    }
    const n: number = this.resultCount;
    return `${n} ${n === 1 ? 'photo' : 'photos'}`;
  }

  // ---------------- detail overlay + find similar

  private openDetail(item: AlbumResultItem): void {
    this.detailId = item.id;
    this.detailName = item.displayName;
    this.detailScore = item.score;
    this.detailIndexed = item.indexed;
    this.detailThumb = null;
    this.showDetailInfo = false;
    this.showDetail = true;
    // drop IME focus so the keyboard cannot squeeze the overlay layout
    // (Google closes the keyboard when the detail dialog opens)
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'clearFocus on openDetail failed: %{public}s', `${e}`);
    }
    this.loadDetailThumb(item.id);
  }

  private closeDetail(): void {
    this.showDetail = false;
    this.showDetailInfo = false;
  }

  // large 720px detail image (separate from the 144px ThumbCache pipeline)
  private async loadDetailThumb(id: string): Promise<void> {
    try {
      let pm: image.PixelMap | null = null;
      if (id.startsWith('file://media/')) {
        let asset: photoAccessHelper.PhotoAsset | undefined = this.assetsByUri.get(id);
        if (asset === undefined) {
          if (!this.assetsLoaded) {
            await this.loadAssetMap();
            asset = this.assetsByUri.get(id);
          }
          if (asset !== undefined) {
            pm = await asset.getThumbnail({ width: 720, height: 720 });
          }
        } else {
          pm = await asset.getThumbnail({ width: 720, height: 720 });
        }
      } else {
        const src: image.ImageSource = image.createImageSource(id);
        try {
          pm = await src.createPixelMap({ desiredSize: { width: 720, height: 720 } });
        } finally {
          src.release();
        }
      }
      if (this.showDetail && this.detailId === id && pm !== null) {
        this.detailThumb = pm;
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'detail thumb failed for %{public}s: %{public}s', id, `${e}`);
    }
  }

  // "Find similar images": sandbox copy -> taskpool imgEmbedTask behind the
  // MNN gate -> cosine rank of every indexed photo except itself -> results
  private async findSimilar(): Promise<void> {
    const mgr: PhotoIndexManager | null = this.manager;
    if (mgr === null || this.detailFinding) {
      return;
    }
    const id: string = this.detailId;
    const local: string | null = mgr.copyPhotoLocalForId(id);
    if (local === null) {
      this.note = 'Could not read the photo for analysis.';
      return;
    }
    this.detailFinding = true;
    try {
      let qvec: Float32Array = new Float32Array(0);
      await MnnGate.acquire();
      try {
        qvec = await taskpool.execute(imgEmbedTask, local) as Float32Array;
      } finally {
        MnnGate.release();
      }
      const items: AlbumResultItem[] = [];
      for (const r of mgr.getRecords()) {
        if (r.status !== 'indexed' || r.id === id) {
          continue;
        }
        const v: Float32Array | undefined = mgr.getVector(r.id);
        if (v === undefined) {
          continue;
        }
        items.push({ id: r.id, displayName: r.displayName, score: cosSim(qvec, v), indexed: true });
      }
      items.sort((a: AlbumResultItem, b: AlbumResultItem) => b.score - a.score);
      const top: AlbumResultItem[] = items.slice(0, Math.min(items.length, 100));
      this.closeDetail();
      this.viewName = 'search';
      this.query = '';
      this.gridMode = 'results';
      this.similarMode = true;
      this.resultCount = top.length;
      this.gridSource.setItems(top);
      hilog.info(0x0000, TAG, 'find similar %{public}s: %{public}d matches, %{public}d shown',
        id, items.length, top.length);
    } catch (e) {
      hilog.error(0x0000, TAG, 'find similar failed: %{public}s', `${e}`);
      this.note = `Find similar failed: ${e}`;
    }
    this.detailFinding = false;
  }

  // ---------------- clustering (US4, M3 restyle)

  private runCluster(): void {
    const mgr: PhotoIndexManager | null = this.manager;
    if (mgr === null || this.indexedCount < 3 || this.clustering) {
      return;
    }
    this.clustering = true;
    this.clusterNote = '';
    setTimeout(() => {
      this.performCluster();
    }, 50);
  }

  private async performCluster(): Promise<void> {
    try {
      const mgr: PhotoIndexManager = this.manager as PhotoIndexManager;
      const result: ClusterResult = mgr.cluster(this.kSetting);
      this.clusterResult = result;
      const groups: ClusterGroupItem[] = [];
      for (let i = 0; i < result.clusters.length; i++) {
        const c: PhotoCluster = result.clusters[i];
        groups.push({
          clusterIndex: i,
          count: c.photoIds.length,
          repId: c.photoIds.length > 0 ? c.photoIds[0] : ''
        });
      }
      groups.sort((a: ClusterGroupItem, b: ClusterGroupItem) => b.count - a.count);
      this.clusterGroups = groups;
      this.viewingGroup = -1;
      this.groupMembers = [];
      hilog.info(0x0000, TAG, 'cluster done: k=%{public}d groups=%{public}d', result.k, groups.length);
    } catch (e) {
      hilog.error(0x0000, TAG, 'cluster failed: %{public}s', `${e}`);
      this.clusterNote = `Clustering failed: ${e}`;
    }
    this.clustering = false;
  }

  private openGroup(clusterIndex: number): void {
    if (this.clusterResult === null || this.manager === null) {
      return;
    }
    const clusters: PhotoCluster[] = this.clusterResult.clusters;
    if (clusterIndex < 0 || clusterIndex >= clusters.length) {
      return;
    }
    const names: Map<string, string> = new Map();
    for (const r of (this.manager as PhotoIndexManager).getRecords()) {
      names.set(r.id, r.displayName);
    }
    const members: GroupMemberItem[] = [];
    for (const id of clusters[clusterIndex].photoIds) {
      const name: string | undefined = names.get(id);
      members.push({ id: id, displayName: name !== undefined ? name : id });
    }
    this.groupMembers = members;
    this.viewingGroup = clusterIndex;
  }

  // ---------------- text helpers

  private userTitle(): string {
    if (!this.hasPermission || this.userCount === 0) {
      return 'Add photos';
    }
    if (this.indexing && this.pendingCount > 0) {
      return `Adding ${this.userCount} photos…`;
    }
    return `${this.userCount} ${this.userCount === 1 ? 'photo' : 'photos'}`;
  }

  private userSubtitle(): string {
    if (!this.hasPermission || this.userCount === 0) {
      return 'Grant access to your photo library';
    }
    if (this.indexing && this.pendingCount > 0) {
      return '';
    }
    return 'Photos that you granted access for';
  }

  private matchPercent(): string {
    return `${Math.round(this.detailScore * 100)}% match`;
  }

  // ---------------- builders

  @Builder
  NoModelView() {
    Column({ space: 12 }) {
      Text('Model not ready')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.m3_on_error_container'))
      Text('Go back to the intro page and finish the model restore / load first.')
        .fontSize(14)
        .fontColor($r('app.color.m3_on_surface_variant'))
        .textAlign(TextAlign.Center)
      Button('Go back')
        .height(44)
        .borderRadius(22)
        .backgroundColor($r('app.color.m3_primary'))
        .fontColor($r('app.color.m3_on_primary'))
        .onClick(() => {
          this.getUIContext().getRouter().back();
        })
    }
    .padding(32)
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  // one landing photo stack: cards centered, count badge bottomEnd
  @Builder
  SampleStack() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack() {
        if (this.sampleStackIds.length === 0) {
          ForEach(PLACEHOLDER_SEQ, (seq: number) => {
            AlbumStackCard({ cardId: '', cardSeq: seq, cardIsAdd: false })
              .zIndex(3 - seq)
          }, (seq: number) => `ph_${seq}`)
        } else {
          ForEach(this.sampleStackIds, (id: string, index: number) => {
            AlbumStackCard({ cardId: id, cardSeq: index, cardIsAdd: false })
              .zIndex(index + 1)
          }, (id: string) => id)
        }
      }
      .width('100%')
      .height('100%')
      Text(`${this.sampleIndexed}`)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .backgroundColor('#D9000000')
        .borderRadius(14)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .offset({ x: 12, y: 12 })
    }
    .width('100%')
    .height(200)
    .onClick(() => {
      this.onSampleStackClick();
    })
  }

  @Builder
  UserStack() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack() {
        if (this.userStackIds.length === 0) {
          ForEach(PLACEHOLDER_SEQ, (seq: number) => {
            AlbumStackCard({ cardId: '', cardSeq: seq, cardIsAdd: seq === 0 })
              .zIndex(3 - seq)
          }, (seq: number) => `ph_${seq}`)
        } else {
          ForEach(this.userStackIds, (id: string, index: number) => {
            AlbumStackCard({ cardId: id, cardSeq: index, cardIsAdd: false })
              .zIndex(index + 1)
          }, (id: string) => id)
        }
      }
      .width('100%')
      .height('100%')
      Text(`${this.userIndexed}`)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .backgroundColor('#D9000000')
        .borderRadius(14)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .offset({ x: 12, y: 12 })
    }
    .width('100%')
    .height(200)
    .onClick(() => {
      this.onUserStackClick();
    })
  }

  @Builder
  LandingView() {
    Column() {
      Scroll() {
        Column() {
          Row() {
            Blank()
            Text('Clusters')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.m3_primary'))
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .onClick(() => {
                this.viewName = 'cluster';
              })
          }
          .width('100%')

          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(36)
            .fontColor([$r('app.color.m3_primary')])
            .margin({ top: 8 })

          Text('Instant Media Search')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.m3_on_surface'))
            .textAlign(TextAlign.Center)
            .margin({ top: 8, bottom: 8 })

          Text() {
            Span('Search your photos on-device with natural language using ')
            Span('EmbeddingGemma 2')
              .fontColor($r('app.color.m3_primary'))
              .fontWeight(FontWeight.Bold)
            Span('! Start searching with some sample images or grant access to your device photos to search your own images!')
          }
          .fontSize(13)
          .fontColor($r('app.color.m3_on_surface_variant'))
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })

          // sample photos stack
          this.SampleStack()
          Text('Sample photos')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.m3_on_surface'))
            .textAlign(TextAlign.Center)
            .margin({ top: 12 })
          Text('Sample photos provided by AI Edge Gallery')
            .fontSize(12)
            .fontColor($r('app.color.m3_on_surface_variant'))
            .textAlign(TextAlign.Center)

          // user photos stack
          Column() {
            this.UserStack()
          }
          .margin({ top: 28 })
          Text(this.userTitle())
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.m3_on_surface'))
            .textAlign(TextAlign.Center)
            .margin({ top: 12 })
          if (this.userSubtitle().length > 0) {
            Text(this.userSubtitle())
              .fontSize(12)
              .fontColor($r('app.color.m3_on_surface_variant'))
              .textAlign(TextAlign.Center)
              .margin({ top: 2 })
          }

          // indexing progress (Google SmartAlbumAnalysisProgressCard, simplified)
          if (this.indexing && this.progressTotal > 0) {
            Column({ space: 6 }) {
              Text(`Indexing photos: ${this.progressProcessed} / ${this.progressTotal} (${this.progressPct()}%)`)
                .fontSize(12)
                .fontColor($r('app.color.m3_on_surface_variant'))
                .textAlign(TextAlign.Center)
              Progress({ value: this.progressProcessed, total: this.progressTotal, type: ProgressType.Linear })
                .height(4)
                .color($r('app.color.m3_primary'))
                .width('80%')
            }
            .width('100%')
            .margin({ top: 16 })
          }

          if (this.importing) {
            Row({ space: 8 }) {
              LoadingProgress()
                .height(18)
                .width(18)
                .color($r('app.color.m3_primary'))
              Text(this.note.length > 0 ? this.note : 'Importing…')
                .fontSize(12)
                .fontColor($r('app.color.m3_on_surface_variant'))
            }
            .margin({ top: 12 })
          } else if (this.note.length > 0) {
            Text(this.note)
              .fontSize(12)
              .fontColor($r('app.color.m3_on_surface_variant'))
              .textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 })
              .margin({ top: 12 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ bottom: 16 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)

      // docked search pill
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(20)
          .fontColor([$r('app.color.m3_on_surface_variant')])
        Text('Search photos…')
          .fontSize(15)
          .fontColor($r('app.color.m3_on_surface_variant'))
      }
      .height(56)
      .borderRadius(28)
      .backgroundColor($r('app.color.m3_surface_container'))
      .shadow({ radius: 8, color: '#1F000000', offsetY: 4 })
      .width('100%')
      .onClick(() => {
        this.openSearchView();
      })
    }
    .padding({ left: 16, right: 16, bottom: 16, top: 4 })
    .width('100%')
    .height('100%')
  }

  @Builder
  SearchView() {
    Column() {
      // top bar: back + query input + clear
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.m3_on_surface_variant')])
          .width(44)
          .height(44)
          .onClick(() => {
            this.exitSearchView();
          })
        TextInput({ text: this.query, placeholder: 'Search for term…' })
          .layoutWeight(1)
          .height(48)
          .fontSize(15)
          .backgroundColor($r('app.color.m3_surface_container_highest'))
          .borderRadius(24)
          .padding({ left: 16, right: 16 })
          .onChange((v: string) => {
            this.onQueryChange(v);
          })
        if (this.query.length > 0) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([$r('app.color.m3_on_surface_variant')])
            .width(44)
            .height(44)
            .onClick(() => {
              this.clearQuery();
            })
        } else {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(20)
            .fontColor([$r('app.color.m3_on_surface_variant')])
            .width(44)
            .height(44)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // warning banner: results are partial while indexing runs
      if (this.gridMode === 'results' && this.pendingCount > 0 && !this.bannerDismissed) {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(20)
            .fontColor([$r('app.color.m3_on_surface_variant')])
          Text('Photos are still being analyzed, so some photos may be missing from your Search results.')
            .fontSize(12)
            .fontColor($r('app.color.m3_on_surface'))
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([$r('app.color.m3_on_surface_variant')])
            .onClick(() => {
              this.bannerDismissed = true;
            })
        }
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius(12)
        .backgroundColor($r('app.color.m3_surface_container'))
        .width('100%')
        .margin({ top: 4 })
      }

      // subheader: count + status
      Row({ space: 8 }) {
        if (this.indexing) {
          LoadingProgress()
            .height(16)
            .width(16)
            .color($r('app.color.m3_primary'))
        } else if (this.gridMode === 'library' && this.resultCount > 0 && this.pendingCount === 0) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(16)
            .fontColor([$r('app.color.m3_on_surface')])
        }
        Text(this.searchHeaderTitle())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.m3_on_surface'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 6 })

      // content: empty states or the lazy grid
      if (this.gridMode === 'library' && this.resultCount === 0) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.ohos_photo'))
            .fontSize(64)
            .fontColor([$r('app.color.m3_on_surface_variant')])
          Text('No photos yet')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.m3_on_surface'))
          Text('Add photos to start searching your collection')
            .fontSize(14)
            .fontColor($r('app.color.m3_on_surface_variant'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.gridMode === 'results' && this.resultCount === 0 && !this.searching) {
        Text(this.similarMode ? 'Similar photos will appear here' : 'No matching media found')
          .fontSize(16)
          .fontColor($r('app.color.m3_on_surface_variant'))
          .width('100%')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 96 })
      } else {
        Grid() {
          LazyForEach(this.gridSource, (item: AlbumResultItem) => {
            GridItem() {
              AlbumGridCell({
                cellId: item.id,
                cellScore: item.score,
                cellIndexed: item.indexed,
                cellLibrary: this.gridMode === 'library',
                onOpen: (id: string) => {
                  this.openDetail(item);
                }
              })
            }
          }, (item: AlbumResultItem) => `${item.id}_${item.score.toFixed(3)}_${item.indexed ? '1' : '0'}`)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(4)
        .rowsGap(4)
        .padding({ left: 8, right: 8, bottom: 24 })
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ClusterView() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.m3_on_surface_variant')])
          .width(44)
          .height(44)
          .onClick(() => {
            this.viewName = 'landing';
          })
        Text('Clusters')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.m3_on_surface'))
        Blank()
      }
      .width('100%')
      .padding({ left: 4, top: 4 })

      if (this.indexedCount < 3) {
        Text('Analyze at least 3 photos to enable clustering')
          .fontSize(14)
          .fontColor($r('app.color.m3_on_surface_variant'))
          .width('100%')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 96 })
      } else {
        Row({ space: 10 }) {
          Text(this.kSetting === 0 ? 'K: auto' : `K: ${this.kSetting}`)
            .fontSize(13)
            .fontColor($r('app.color.m3_on_surface'))
            .width(64)
          Slider({ value: this.kSetting, min: 0, max: 12, step: 1 })
            .layoutWeight(1)
            .selectedColor($r('app.color.m3_primary'))
            .blockColor($r('app.color.m3_primary'))
            .onChange((v: number) => {
              this.kSetting = Math.round(v);
              this.clusterGroups = [];
              this.viewingGroup = -1;
              this.groupMembers = [];
            })
          Button(this.clustering ? 'Clustering…' : 'Cluster')
            .height(36)
            .borderRadius(18)
            .fontSize(13)
            .backgroundColor($r('app.color.m3_primary'))
            .fontColor($r('app.color.m3_on_primary'))
            .enabled(!this.clustering)
            .onClick(() => {
              this.runCluster();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

        if (this.clustering) {
          Column({ space: 10 }) {
            LoadingProgress()
              .height(28)
              .width(28)
              .color($r('app.color.m3_primary'))
            Text('Clustering analyzed photos on-device…')
              .fontSize(13)
              .fontColor($r('app.color.m3_on_surface_variant'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.clusterNote.length > 0) {
          Text(this.clusterNote)
            .fontSize(13)
            .fontColor($r('app.color.m3_on_error_container'))
            .width('100%')
            .padding({ left: 16, right: 16 })
        } else if (this.viewingGroup >= 0) {
          Column() {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(20)
                .fontColor([$r('app.color.m3_on_surface_variant')])
                .width(36)
                .height(36)
                .onClick(() => {
                  this.viewingGroup = -1;
                  this.groupMembers = [];
                })
              Text(`${this.groupMembers.length} ${this.groupMembers.length === 1 ? 'photo' : 'photos'}`)
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.m3_on_surface'))
              Blank()
            }
            .width('100%')
            .padding({ left: 12 })
            List({ space: 8 }) {
              ForEach(this.groupMembers, (m: GroupMemberItem) => {
                ListItem() {
                  AlbumMemberRow({ rowId: m.id, rowName: m.displayName })
                }
              }, (m: GroupMemberItem) => m.id)
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 16 })
          }
          .width('100%')
          .layoutWeight(1)
        } else if (this.clusterGroups.length > 0) {
          Grid() {
            ForEach(this.clusterGroups, (g: ClusterGroupItem) => {
              GridItem() {
                Column({ space: 6 }) {
                  if (g.repId.length > 0) {
                    AlbumGridCell({
                      cellId: g.repId,
                      cellScore: -1,
                      cellIndexed: true,
                      cellLibrary: false,
                      onOpen: (id: string) => {
                        this.openGroup(g.clusterIndex);
                      }
                    })
                  }
                  Text(`${g.count} ${g.count === 1 ? 'photo' : 'photos'}`)
                    .fontSize(13)
                    .fontColor($r('app.color.m3_on_surface'))
                }
                .padding(6)
                .borderRadius(16)
                .backgroundColor($r('app.color.m3_surface_container'))
                .width('100%')
              }
            }, (g: ClusterGroupItem) => `${g.clusterIndex}_${g.count}_${g.repId}`)
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(8)
          .rowsGap(8)
          .padding({ left: 16, right: 16, bottom: 24 })
          .layoutWeight(1)
          .width('100%')
        } else {
          Text('Set K (0 = auto) and tap Cluster to group analyzed photos by semantic similarity.')
            .fontSize(13)
            .fontColor($r('app.color.m3_on_surface_variant'))
            .width('100%')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 96, left: 32, right: 32 })
        }
      }
    }
    .width('100%')
    .height('100%')
  }

  // access dialog: "Start analyzing media?" (Google PhotoLibraryAccessDialog)
  @Builder
  AccessDialogView() {
    Column() {
      Column({ space: 12 }) {
        Text('Start analyzing media?')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.m3_on_surface'))
          .textAlign(TextAlign.Center)
          .margin({ top: 12, bottom: 12 })
        Button('Select media')
          .height(52)
          .borderRadius(26)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .backgroundColor($r('app.color.m3_secondary_container'))
          .fontColor($r('app.color.m3_on_secondary_container'))
          .width('100%')
          .onClick(() => {
            this.onSelectMedia();
          })
        Button('Bulk select media')
          .height(52)
          .borderRadius(26)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .backgroundColor($r('app.color.m3_secondary_container'))
          .fontColor($r('app.color.m3_on_secondary_container'))
          .width('100%')
          .onClick(() => {
            this.onBulkSelect();
          })
        Button('Cancel')
          .height(52)
          .borderRadius(26)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.m3_primary'))
          .width('100%')
          .onClick(() => {
            this.showAccessDialog = false;
          })
      }
      .padding(24)
      .borderRadius(28)
      .backgroundColor($r('app.color.m3_surface_container_high'))
      .width('88%')
      .onClick(() => {
      })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .onClick(() => {
      this.showAccessDialog = false;
    })
  }

  // bulk-select bottom sheet (Google StartAnalyzingAllPhotosBottomSheet)
  @Builder
  BulkSheetView() {
    Column() {
      Column({ space: 12 }) {
        Text('Bulk select media')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.m3_on_surface'))
          .textAlign(TextAlign.Center)
          .margin({ top: 20 })
        Text('Select how many media items you’d like to get analyzed. We recommend under 250 media items.')
          .fontSize(14)
          .fontColor($r('app.color.m3_on_surface_variant'))
          .textAlign(TextAlign.Center)
        Text(`Analyze most recent ${this.bulkNum()} ${this.bulkNum() === 1 ? 'item' : 'items'}`)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.m3_on_surface'))
          .margin({ top: 12 })
        TextInput({ text: this.bulkCount })
          .type(InputType.Number)
          .width(140)
          .height(48)
          .fontSize(16)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.m3_surface_container_highest'))
          .onChange((v: string) => {
            const digits: string = v.replace(/[^0-9]/g, '');
            if (digits.length === 0) {
              this.bulkCount = '0';
              return;
            }
            const parsed: number = parseInt(digits);
            this.bulkCount = `${Math.min(parsed, this.bulkMax)}`;
          })
        if (this.bulkMax > 0) {
          Slider({ value: this.bulkNum(), min: 0, max: this.bulkMax, step: 1 })
            .width('100%')
            .selectedColor($r('app.color.m3_primary'))
            .blockColor($r('app.color.m3_primary'))
            .margin({ top: 8 })
            .onChange((v: number) => {
              this.bulkCount = `${Math.round(v)}`;
            })
        }
        Text(`of ${this.bulkMax} available`)
          .fontSize(12)
          .fontColor($r('app.color.m3_on_surface_variant'))
        if (this.bulkMax > 250 && this.bulkNum() >= this.bulkMax) {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
              .fontSize(20)
              .fontColor([$r('app.color.m3_on_error_container')])
            Column({ space: 2 }) {
              Text('Are you sure you want to select all media?')
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.m3_on_error_container'))
              Text('You’ll start analyzing all media on your device. EmbeddingGemma 2 may not be optimized for this device, so this may take a long time.')
                .fontSize(12)
                .fontColor($r('app.color.m3_on_error_container'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .borderRadius(12)
          .backgroundColor($r('app.color.m3_error_container'))
          .width('100%')
        }
        Button('Yes, analyze selected media')
          .height(52)
          .borderRadius(26)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .backgroundColor($r('app.color.m3_secondary_container'))
          .fontColor($r('app.color.m3_on_secondary_container'))
          .width('100%')
          .enabled(this.bulkNum() > 0)
          .margin({ top: 12 })
          .onClick(() => {
            this.onBulkConfirm();
          })
        Button('Cancel')
          .height(52)
          .borderRadius(26)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.m3_primary'))
          .width('100%')
          .onClick(() => {
            this.showBulkSheet = false;
          })
      }
      .padding({ left: 24, right: 24, bottom: 32 })
      .borderRadius({ topLeft: 28, topRight: 28 })
      .backgroundColor($r('app.color.m3_surface_container'))
      .width('100%')
      .onClick(() => {
      })
    }
    .justifyContent(FlexAlign.End)
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .onClick(() => {
      this.showBulkSheet = false;
    })
  }

  // full-screen photo detail (Google PhotoDetailDialog, single-photo variant)
  @Builder
  DetailInfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.m3_on_surface_variant'))
      Blank()
      Text(value)
        .fontSize(13)
        .fontColor($r('app.color.m3_on_surface'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
  }

  @Builder
  DetailView() {
    Column() {
      // top bar
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.m3_on_surface_variant')])
          .width(44)
          .height(44)
          .onClick(() => {
            this.closeDetail();
          })
        Text(this.detailName)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.m3_on_surface'))
          .layoutWeight(1)
          .maxLines(1)
          .textAlign(TextAlign.Center)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor([$r('app.color.m3_on_surface_variant')])
          .width(44)
          .height(44)
          .onClick(() => {
            this.closeDetail();
          })
      }
      .width('100%')

      // photo area: large image + match badge + find-similar pill
      Stack({ alignContent: Alignment.Bottom }) {
        Stack({ alignContent: Alignment.TopStart }) {
          if (this.detailThumb !== null) {
            Image(this.detailThumb)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
          } else {
            Column({ space: 12 }) {
              LoadingProgress()
                .height(28)
                .width(28)
                .color($r('app.color.m3_primary'))
              Text('Loading photo…')
                .fontSize(13)
                .fontColor($r('app.color.m3_on_surface_variant'))
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.m3_surface_container'))
          }
          if (this.detailScore >= 0) {
            Text(this.matchPercent())
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.m3_on_secondary_container'))
              .backgroundColor($r('app.color.m3_secondary_container'))
              .borderRadius(16)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .margin({ left: 16, top: 16 })
          }
        }
        .width('100%')
        .height('100%')

        // bottom action pill: "Find similar images"
        Row({ space: 8 }) {
          if (this.detailFinding) {
            LoadingProgress()
              .height(20)
              .width(20)
              .color($r('app.color.m3_on_primary_container'))
          } else {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(20)
              .fontColor([$r('app.color.m3_on_primary_container')])
          }
          Text('Find similar images')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.m3_on_primary_container'))
        }
        .padding({ left: 24, right: 24, top: 12, bottom: 12 })
        .borderRadius(28)
        .backgroundColor($r('app.color.m3_primary_container'))
        .shadow({ radius: 8, color: '#1F000000', offsetY: 4 })
        .margin({ bottom: 16 })
        .onClick(() => {
          this.findSimilar();
        })
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor($r('app.color.m3_surface_container'))

      // expandable embedding info bar
      Column() {
        Row() {
          Text('Embedding info')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.m3_on_surface'))
          Blank()
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(18)
            .fontColor([$r('app.color.m3_on_surface_variant')])
            .rotate({ angle: this.showDetailInfo ? 180 : 0 })
        }
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .width('100%')
        .onClick(() => {
          this.showDetailInfo = !this.showDetailInfo;
        })

        if (this.showDetailInfo) {
          Divider()
            .color($r('app.color.m3_outline'))
            .opacity(0.3)
          this.DetailInfoRow('Model', 'EmbeddingGemma-2 (MNN)')
          this.DetailInfoRow('Dimensions', '768')
          this.DetailInfoRow('Status', this.detailIndexed ? 'Analyzed' : 'Analyzing…')
          this.DetailInfoRow('Similarity', this.detailScore >= 0 ? this.detailScore.toFixed(4) : '—')
          this.DetailInfoRow('Processing', 'On-device')
        }
      }
      .width('100%')
      .borderRadius({ topLeft: 20, topRight: 20 })
      .backgroundColor($r('app.color.m3_surface_container_high'))
      .padding({ bottom: this.showDetailInfo ? 12 : 0 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.m3_surface'))
  }

  build() {
    Stack() {
      Column() {
        if (this.pageState === 'nomodel') {
          this.NoModelView()
        } else if (this.pageState === 'init') {
          Column({ space: 12 }) {
            LoadingProgress()
              .height(32)
              .width(32)
              .color($r('app.color.m3_primary'))
            Text('Initializing on-device model…')
              .fontSize(14)
              .fontColor($r('app.color.m3_on_surface_variant'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.viewName === 'landing') {
          this.LandingView()
        } else if (this.viewName === 'search') {
          this.SearchView()
        } else {
          this.ClusterView()
        }
      }
      .width('100%')
      .height('100%')

      if (this.showAccessDialog) {
        this.AccessDialogView()
      }
      if (this.showBulkSheet) {
        this.BulkSheetView()
      }
      if (this.showDetail) {
        this.DetailView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.m3_surface'))
  }
}
