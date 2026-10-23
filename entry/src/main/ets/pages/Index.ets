// SemSearch (Phase 14, T040): Google AI Edge Gallery task-intro page replica.
// Layout copied from the "Instant Media Search" intro screen observed on the
// real device (T038 container dump): title / subtitle / Example code /
// "1 models available" / "Recommended models" / model card (Best overall,
// EmbeddingGemma-2, size, license line, description, embedded restore+init
// progress) / "Try it" pill button that opens the Smart Album page.
// Engine bootstrap (rawfile restore -> taskpool initTask behind MnnGate) is
// carried over unchanged from the previous home page. The text self-check,
// doc-demo and quick-query UI were removed per Phase 14 scope decision.
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import { taskpool } from '@kit.ArkTS';
import { prepareDir } from 'libentry.so';
import { initTask } from '../common/EmbedTasks';
import { RawInstaller, RawCopyProgress } from '../common/RawInstaller';
import { MnnGate } from '../common/MnnGate';

const MODEL_FILES: string[] = [
  'config.json',
  'llm_config.json',
  'embedding.mnn',
  'embedding.mnn.weight',
  'visual.mnn',
  'visual.mnn.weight',
  'tokenizer.mtok',
  'embeddings_bf16.bin'
];

// FR-009 (revised): full packaged model set (rawfile/eg2v_int8) — the 8 runtime
// files above plus export_args.json, streamed into files/model on first launch.
const RAW_MODEL_FILES: string[] = MODEL_FILES.concat(['export_args.json']);

@Entry
@Component
struct Index {
  @State modelStatus: string = 'loading'; // loading | ready | missing
  @State modelDir: string = '';
  @State restoring: boolean = false;
  @State restoreInfo: string = '';
  @State restoreProgress: string = '';
  @State downloading: boolean = false;
  @State downloadInfo: string = '';
  @State progress: string = '';
  @State baseUrl: string = 'http://10.240.105.78:8000/eg2v_int8';

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const local = context.filesDir + '/model';
    // create model dir with 0777 so external tooling can also push files into it
    prepareDir(local);
    this.modelDir = local;
    this.bootstrap();
  }

  // A cold init() blocks 11s+ (page cache miss). It must never run inside
  // aboutToAppear on the UI thread — the system thread watchdog kills the app
  // (ArkUIRunPageUrl THREAD_BLOCK_6S). All engine loads go through taskpool.
  private async bootstrap(): Promise<void> {
    await this.tryInit();
    if (this.modelStatus === 'missing') {
      // FR-009 (revised): offline-first — stream the packaged model out of the
      // HAP rawfile into files/model. The HTTP download below stays as the
      // explicit fallback inside the model card (no auto-download).
      await this.restoreFromRawfile();
    }
    hilog.info(0x0000, 'SemSearch', 'intro bootstrap done, modelStatus=%{public}s', this.modelStatus);
  }

  // FR-009 (revised): stream the packaged model (rawfile/eg2v_int8, ~647MB)
  // into files/model once. Chunked getRawFd fd+offset+length copy inside
  // RawInstaller (never getRawFileContent for these — 600MB would OOM);
  // per-file progress + size-verified idempotent resume (complete files are
  // skipped, so restarts and HTTP-downgraded installs only fill the gaps).
  async restoreFromRawfile(): Promise<void> {
    if (this.restoring || this.modelStatus === 'ready') {
      return;
    }
    this.restoring = true;
    this.restoreInfo = 'Restoring model from package…';
    this.restoreProgress = '';
    const sw = Date.now();
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const installer: RawInstaller = new RawInstaller(context);
      const ok: boolean = await installer.installRawDir('eg2v_int8', RAW_MODEL_FILES, this.modelDir,
        (p: RawCopyProgress) => {
          this.restoreInfo = `Restoring ${p.fileIndex}/${p.fileCount} ${p.fileName}`;
          this.restoreProgress =
            `${(p.copiedBytes / 1024 / 1024).toFixed(1)}/${(p.fileTotal / 1024 / 1024).toFixed(1)} MB`;
        });
      if (ok) {
        hilog.info(0x0000, 'SemSearch', 'rawfile model restore done in %{public}d ms', Date.now() - sw);
        this.restoreInfo = '';
        await this.tryInit();
      } else {
        this.restoreInfo = 'Model resources missing from package';
      }
    } catch (e) {
      this.restoreInfo = `Restore failed: ${e}`;
      hilog.error(0x0000, 'SemSearch', 'rawfile restore failed: %{public}s', `${e}`);
    }
    this.restoreProgress = '';
    this.restoring = false;
  }

  private async tryInit(): Promise<void> {
    if (fileIo.accessSync(this.modelDir + '/config.json')) {
      try {
        await MnnGate.acquire();
        let ok: boolean = false;
        try {
          ok = await taskpool.execute(initTask, this.modelDir) as boolean;
        } finally {
          MnnGate.release();
        }
        if (ok) {
          this.modelStatus = 'ready';
          return;
        }
      } catch (e) {
        hilog.error(0x0000, 'SemSearch', 'init task failed: %{public}s', `${e}`);
      }
    }
    this.modelStatus = 'missing';
  }

  async downloadFile(url: string, dest: string): Promise<void> {
    const client = http.createHttp();
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const localFile = file;
      client.on('dataReceive', (data: ArrayBuffer) => {
        fileIo.writeSync(localFile.fd, data);
      });
      client.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo) => {
        this.progress = `${(info.receiveSize / 1024 / 1024).toFixed(1)}/${(info.totalSize / 1024 / 1024).toFixed(1)} MB`;
      });
      const code = await client.requestInStream(url, { connectTimeout: 15000 });
      if (code !== 200) {
        throw new Error('HTTP ' + code + ' for ' + url);
      }
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
      client.destroy();
    }
  }

  async downloadModel(): Promise<void> {
    if (this.downloading || this.modelStatus === 'ready') {
      return;
    }
    this.downloading = true;
    const base = this.baseUrl.trim().replace(/\/+$/, '');
    try {
      for (let i = 0; i < MODEL_FILES.length; i++) {
        const name = MODEL_FILES[i];
        this.downloadInfo = `${i + 1}/${MODEL_FILES.length} ${name}`;
        this.progress = '';
        const sw = Date.now();
        await this.downloadFile(`${base}/${name}`, this.modelDir + '/' + name);
        hilog.info(0x0000, 'SemSearch', 'downloaded %{public}s in %{public}d ms', name, Date.now() - sw);
      }
      this.downloadInfo = '';
      await this.tryInit();
    } catch (e) {
      this.downloadInfo = `Download failed: ${e}`;
      hilog.error(0x0000, 'SemSearch', 'download failed: %{public}s', `${e}`);
    }
    this.downloading = false;
  }

  // ---- model card status area (restore / init / ready / missing fallback)
  @Builder
  ModelStatusArea()
  {
    if (this.restoring) {
      Row({ space: 10 }) {
        LoadingProgress()
          .height(18)
          .width(18)
          .color($r('app.color.m3_primary'))
        Column({ space: 2 }) {
          Text(this.restoreInfo)
            .fontSize(13)
            .fontColor($r('app.color.m3_on_surface_variant'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.restoreProgress.length > 0) {
            Text(this.restoreProgress)
              .fontSize(12)
              .fontColor($r('app.color.m3_on_surface_variant'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
    } else if (this.modelStatus === 'loading') {
      Row({ space: 10 }) {
        LoadingProgress()
          .height(18)
          .width(18)
          .color($r('app.color.m3_primary'))
        Text('Model initializing… Please wait a few moments')
          .fontSize(13)
          .fontColor($r('app.color.m3_on_surface_variant'))
          .layoutWeight(1)
      }
      .width('100%')
    } else if (this.modelStatus === 'ready') {
      Text('✓ Ready — runs fully on-device')
        .fontSize(13)
        .fontColor($r('app.color.m3_primary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
    } else {
      // missing: hidden HTTP fallback (rawfile restore already tried in bootstrap)
      Column({ space: 8 }) {
        Text(this.restoreInfo.length > 0 ? this.restoreInfo : 'Model files not available')
          .fontSize(13)
          .fontColor($r('app.color.m3_on_error_container'))
          .width('100%')
        TextInput({ text: this.baseUrl })
          .onChange((v: string) => {
            this.baseUrl = v;
          })
          .height(40)
          .fontSize(12)
          .backgroundColor($r('app.color.m3_surface_container_highest'))
          .width('100%')
        Button(this.downloading ? 'Downloading…' : 'Download via HTTP')
          .height(44)
          .borderRadius(22)
          .backgroundColor($r('app.color.m3_primary_container'))
          .fontColor($r('app.color.m3_on_primary_container'))
          .fontSize(14)
          .width('100%')
          .enabled(!this.downloading)
          .onClick(() => {
            this.downloadModel();
          })
        if (this.downloadInfo.length > 0 || this.progress.length > 0) {
          Text(`${this.downloadInfo}${this.progress.length > 0 ? ' · ' + this.progress : ''}`)
            .fontSize(12)
            .fontColor($r('app.color.m3_on_surface_variant'))
            .width('100%')
        }
      }
      .width('100%')
    }
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 0 }) {
          Text('Instant Media Search')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.m3_on_surface'))
            .width('100%')
            .margin({ top: 48, bottom: 12 })

          Text('Organize and search your photos and videos locally with EmbeddingGemma 2')
            .fontSize(14)
            .fontColor($r('app.color.m3_on_surface_variant'))
            .width('100%')
            .margin({ bottom: 8 })

          Text('Example code')
            .fontSize(14)
            .fontColor($r('app.color.m3_primary'))
            .width('100%')
            .margin({ bottom: 24 })

          Text('1 models available')
            .fontSize(12)
            .fontColor($r('app.color.m3_on_surface_variant'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 4 })

          Text('Recommended models')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.m3_on_surface'))
            .width('100%')
            .margin({ bottom: 8 })

          // ---- model card (M3 filled card, radius 28)
          Column({ space: 10 }) {
            Row() {
              Text('Best overall')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.m3_on_surface_variant'))
              Blank()
            }
            .width('100%')

            Text('EmbeddingGemma-2')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.m3_on_surface'))
              .width('100%')

            Text('647 MB')
              .fontSize(14)
              .fontColor($r('app.color.m3_on_surface_variant'))
              .width('100%')

            Text('Learn more and see model license')
              .fontSize(12)
              .fontColor($r('app.color.m3_primary'))
              .width('100%')

            Divider()
              .color($r('app.color.m3_outline'))
              .opacity(0.3)
              .margin({ top: 2, bottom: 2 })

            Text('A variant of EmbeddingGemma 2 optimized for on-device deployment with MNN. It is a multimodal embedding model with image and text understanding, producing 768-dimensional embeddings locally.')
              .fontSize(14)
              .fontColor($r('app.color.m3_on_surface_variant'))
              .width('100%')

            this.ModelStatusArea()
          }
          .padding(24)
          .borderRadius(28)
          .backgroundColor($r('app.color.m3_surface_container_high'))
          .width('100%')
          .margin({ bottom: 24 })

          Button('Try it')
            .height(52)
            .borderRadius(26)
            .backgroundColor($r('app.color.m3_primary'))
            .fontColor($r('app.color.m3_on_primary'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .width('100%')
            .enabled(this.modelStatus === 'ready')
            .onClick(() => {
              router.pushUrl({ url: 'pages/Album' });
            })
        }
        .padding({ left: 28, right: 28, bottom: 32 })
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
    }
    .backgroundColor($r('app.color.m3_surface'))
    .width('100%')
    .height('100%')
  }
}
