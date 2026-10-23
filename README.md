# SemSearch — On-device Semantic Photo Search (HarmonyOS)

端上语义照片搜索应用：照片/文本经 **EmbeddingGemma-2**（MNN int8，768 维）在设备本地编码，支持自然语言搜图、图搜图与自动聚类。UI 全流程参照 Google [AI Edge Gallery](https://github.com/google-ai-edge/gallery) Smart Album（Material 3），引擎为自研 D1 链路。

## 功能

- **语义搜索**：输入即搜（300ms debounce），中文/英文均可（"花园里的花"、"a dog"），结果按相似度降序、tile 标注 `%match`
- **图搜图（Find similar images）**：照片详情页一键以图检索全库相似照片
- **自动聚类（Clusters）**：K-means 向量聚类，支持自动 K / 手动 K，语义分组（动物、食物等）
- **断点续索引**：索引中断可续跑；新增照片只索引增量
- **M3 双主题**：浅色/深色模式全量适配
- **示例数据**：rawfile 内置 21 张 seed 照片，一键导入体验完整流程

## 实测性能（华为 Pura 80 Pro，Kirin 9020）

| 指标 | 数值 |
|------|------|
| 索引速度 | **1.91 s/张**（MNN 70-token，D1 引擎） |
| 单图编码（图搜图） | ~1.2 s |
| 文本/向量检索（千级库） | < 1 s |
| 嵌入维度 | 768（float32） |

## 构建前提

1. DevEco Studio（含 HarmonyOS SDK，本工程按 API 26 编译）
2. JDK 21（`JAVA_HOME` 指向 JDK 21）
3. **模型权重**（见下节，必需）

## 模型权重（不入库，需自行放置）

GitHub 单文件上限 100MB，以下权重文件已被 `.gitignore` 排除，clone 后必须补齐才能构建出可运行的 HAP：

放置目录：`entry/src/main/resources/rawfile/eg2v_int8/`

| 文件 | 大小 | 说明 |
|------|------|------|
| `embedding.mnn.weight` | 156 MB | 文本编码器权重 |
| `visual.mnn.weight` | 215 MB | 视觉编码器权重 |
| `embeddings_bf16.bin` | 256 MB | LLM 层嵌入表 |

同目录其余文件（`embedding.mnn`、`visual.mnn`、`tokenizer.mtok`、`config.json`、`llm_config.json`、`export_args.json`）均已入库，无需额外获取。

权重来源（二选一）：

1. **打包进 HAP（推荐）**：将上述 3 个文件复制到放置目录后正常构建。应用首启会从 rawfile 流式恢复到沙箱 `files/model`。
2. **LAN HTTP 回退**：在 PC 上用 `python -m http.server 8000` 起一个服务，根目录含 `eg2v_int8/`；将 `entry/src/main/ets/pages/Index.ets` 中 `baseUrl`（默认 `http://10.240.105.78:8000/eg2v_int8`）改为 PC 的局域网地址，模型卡内"Download via HTTP"按钮即可下载。手机与 PC 需同一网络。

> 应用内已内置校验：权重缺失时模型卡显示未就绪，不会崩溃。

## 构建

```bash
# DevEco Studio 命令行
hvigorw assembleHap --mode module -p product=default
# 或 IDE 内 Build > Build Hap(s)/APP(s)
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`（含权重约 655MB）。

## 运行

```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.example.semsearch
```

权限：首次进入相册页会申请 `ohos.permission.READ_IMAGEVIDEO`（用户图库索引）。

## 工程结构

```
entry/src/main/
├── cpp/                    # native：MNN 推理封装（embedding_napi.cpp → libentry.so）
├── ets/
│   ├── pages/
│   │   ├── Index.ets       # Google 风格任务介绍页（模型卡、rawfile 恢复进度、Try it）
│   │   └── Album.ets       # SmartAlbum 落地页 + 搜索 + 详情 + 图搜图 + 聚类（单页状态机）
│   └── common/
│       ├── MnnGate.ets     # 推理并发门控（防 taskpool 并发挤压）
│       ├── EmbedTasks.ets  # taskpool 任务：initTask/imgEmbedTask/visualInitTask
│       ├── RawInstaller.ets# rawfile → 沙箱流式恢复
│       ├── PhotoIndexManager.ets  # 照片索引/向量库/聚类/同步
│       └── ThumbCache.ets  # 全局缩略图缓存（inflight 去重 + LRU）
└── resources/
    ├── base|dark/element/color.json  # M3 双主题色板
    └── rawfile/
        ├── eg2v_int8/      # 模型（权重除外均已入库）
        └── album_seed/     # 21 张示例照片
```

## 设计与验证记录

开发全程采用 spec 驱动（T001–T044），含 D0–D3 引擎四路基准（MNN int8/fp16、LiteRT、NPU）、Google AI Edge Gallery 容器实机基准对照、真机逐屏 uitest 自动化验证。详细任务记录见仓库外 `spec/photo-semantic-search/tasks.md`。

## License

模型权重与 MNN 相关组件遵循其各自原始许可（EmbeddingGemma：Gemma Terms of Use；MNN：Apache-2.0）。应用代码部分仅作学习研究用途。
