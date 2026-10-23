# SemSearch

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

鸿蒙端上的本地照片语义搜索。照片和文本用 EmbeddingGemma-2 在设备本地编码成 768 维向量，支持自然语言搜图、以图搜图、聚类，全程不联网。

UI 参考 Google [AI Edge Gallery](https://github.com/google-ai-edge/gallery) 的 Smart Album（Material 3）照抄了一遍，引擎是自己调的 MNN int8 链路。

## 演示

真机录屏（Pura 80 Pro，清数据后全新流程：恢复模型 → 导入种子照片 → 索引 → 中英文搜索 → 详情 → 图搜图 → 聚类）：

<video src="docs/demo.mp4" controls muted width="270"></video>

<p>
<img width="200" alt="intro" src="docs/01_intro.jpg" />
<img width="200" alt="landing" src="docs/02_landing.jpg" />
<img width="200" alt="indexing" src="docs/03_indexing.jpg" />
<img width="200" alt="search" src="docs/04_search_adog.jpg" />
</p>
<p>
<img width="200" alt="chinese" src="docs/05_search_chinese.jpg" />
<img width="200" alt="detail" src="docs/06_detail_embedding.jpg" />
<img width="200" alt="similar" src="docs/07_find_similar.jpg" />
<img width="200" alt="clusters" src="docs/08_clusters.jpg" />
</p>

## 和 Google 官方实现的对比

同一台手机（Pura 80 Pro）实测。Google 的数据是跑在卓易通容器里测的，有容器开销，数字仅供参考：

| | SemSearch | AI Edge Gallery |
|---|---|---|
| 索引 | 1.91 s/张 | 2.61 s/张 |
| 图搜图单次 | ~1.2 s | 2.6 ~ 4.9 s |
| 文本检索（千级库） | < 1 s | < 1 s |
| 聚类 | 有 | 没有 |
| 中文查询 | 可以 | 可以 |

1600 张照片估算：这边约 51 分钟，Google 栈约 70 分钟。

### 快在哪

主要是一个改动：把视觉 soft token 预算从官方默认的 280 压到 70（`llm_config.json` 里的 `vision_soft_token_budget`）。嵌入模型的 prefill 计算量跟 soft token 数成正比，砍掉 3/4，索引速度就上来了。

质量验证过：自检基准花 0.7174 / 狗 0.5698，中英文检索、聚类、图搜图全链路都正常。代价是复杂场景（多人、密集小物体）的细粒度区分理论上会弱一些——21 张 seed 图的规模暴露不出来，大图库上待观察。

另外几个点：

- 权重 int8，但 LLM 嵌入表单独保留 bf16（`embeddings_bf16.bin`）。查表不走 int8，省不了多少计算，精度损失却不小，不值得。
- taskpool 里的推理任务串行过闸（MnnGate）。并发推理在端侧只会争 CPU，实测会 appfreeze。
- 索引断点可续，新增照片只跑增量，不重扫全库。
- 聚类是 Google 版没有的：K-means 向量聚类，K 可以自动估，也可以手动拉。

## 构建

需要 DevEco Studio（API 26）和 JDK 21。

模型权重没进仓库（GitHub 单文件限 100MB，最大一个 256MB）。构建前把这三个文件放到 `entry/src/main/resources/rawfile/eg2v_int8/`：

| 文件 | 大小 |
|------|------|
| `embedding.mnn.weight` | 156 MB |
| `visual.mnn.weight` | 215 MB |
| `embeddings_bf16.bin` | 256 MB |

同目录其它文件（`*.mnn`、`tokenizer.mtok`、`config.json` 等）都在仓库里，不用管。不想打包的话也可以：PC 上 `python -m http.server 8000`，把 `Index.ets` 里的 `baseUrl` 改成 PC 的局域网地址，应用内会多出一个 HTTP 下载按钮（手机和 PC 要在同一网络）。

```bash
hvigorw assembleHap --mode module -p product=default
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.example.semsearch
```

含权重的 HAP 大概 655MB，首启会从 rawfile 流式恢复到沙箱，之后不用再拷。

## 工程结构

```
entry/src/main/
├── cpp/                    # NAPI 封装 MNN 推理（embedding_napi.cpp → libentry.so）
├── ets/
│   ├── pages/
│   │   ├── Index.ets       # 介绍页：模型卡 + 恢复进度 + Try it
│   │   └── Album.ets       # 落地页/搜索/详情/图搜图/聚类，单页状态机
│   └── common/
│       ├── MnnGate.ets     # 推理并发门控
│       ├── EmbedTasks.ets  # taskpool 任务
│       ├── RawInstaller.ets# rawfile → 沙箱恢复
│       ├── PhotoIndexManager.ets  # 索引、向量库、聚类、增量同步
│       └── ThumbCache.ets  # 缩略图缓存
└── resources/
    ├── base|dark/element/color.json
    └── rawfile/            # 模型 + 21 张 seed 照片
```

## 许可

代码 Apache-2.0。第三方的东西各归各：MNN（Apache-2.0）、EmbeddingGemma-2（[Gemma 条款](https://ai.google.dev/gemma/terms)）、UI 参照的 AI Edge Gallery（Apache-2.0），详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
