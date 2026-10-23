# SemSearch

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

SemSearch 是一个运行在 HarmonyOS 上的端侧照片语义搜索应用。照片与文本经 EmbeddingGemma-2 在设备本地编码为 768 维向量，支持自然语言搜索、以图搜图与自动聚类，所有推理在设备上完成，无需联网。

UI 参照 Google [AI Edge Gallery](https://github.com/google-ai-edge/gallery) 的 Smart Album 实现，推理引擎基于 MNN int8 链路优化，同机实测索引速度比 Google 官方实现快约 27%（见下方对比数据）。

## 演示

真机录制（华为 Pura 80 Pro），完整流程：模型恢复 → 示例照片导入 → 索引 → 中英文语义搜索 → 照片详情 → 以图搜图 → 自动聚类。

<video src="docs/demo.mp4" controls muted width="270"></video>

## 界面预览

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

## 功能

- **语义搜索**：输入即搜（300ms debounce），支持中英文，结果按相似度降序排列并标注匹配度
- **以图搜图**：详情页一键检索全库相似照片，单图编码约 1.2 s
- **自动聚类**：K-means 向量聚类，支持自动估计 K 值或手动指定，是 Google 版没有的扩展能力
- **断点续索引**：索引中断后可从断点续跑，新增照片只处理增量
- **深浅双主题**：Material 3 风格，深色模式完整适配
- **内置示例**：rawfile 自带 21 张示例照片，安装后即可体验完整流程

## 与 Google 官方实现的对比

同一设备（Pura 80 Pro）实测。Google 侧运行于卓易通容器，存在容器开销，数据供参考：

| 指标 | SemSearch | AI Edge Gallery |
|------|-----------|-----------------|
| 索引速度 | **1.91 s/张** | 2.61 s/张 |
| 视觉 token 预算 | 70 | 280 |
| 以图搜图单次耗时 | **~1.2 s** | 2.6 ~ 4.9 s |
| 文本检索（千级库） | < 1 s | < 1 s |
| 量化方案 | int8 权重 + bf16 嵌入表 | int8 |
| 自动聚类 | 支持 | 不支持 |
| 中文查询 | 支持 | 支持 |

1600 张照片索引估算：SemSearch 约 51 分钟，Google 栈约 70 分钟。

### 性能差异的来源

主要来自视觉 token 预算：嵌入模型的 prefill 计算量与 soft token 数成正比，将 `llm_config.json` 中的 `vision_soft_token_budget` 从官方默认的 280 压缩至 70，索引速度提升约 27%。质量经自检基准（花 0.7174 / 狗 0.5698）及中英文检索、聚类、以图搜图全链路验证，保持在可用区间；代价是复杂场景（多人、密集小物体）的细粒度区分能力理论上有所减弱，大规模图库上的表现有待观察。

其它工程优化：

- **混合精度**：LLM 嵌入表单独保留 bf16（`embeddings_bf16.bin`），查表不量化，避免嵌入精度损失
- **MnnGate 并发门控**：taskpool 推理任务串行过闸，避免端侧并发推理导致 CPU 争抢和应用冻结
- **ThumbCache**：全局缩略图缓存，inflight 去重 + 容量上限淘汰，网格滚动不重复解码

## 技术栈

- HarmonyOS ArkTS / ArkUI（API 26），taskpool 多线程
- NAPI + C++：`libentry.so` 直连 MNN 推理引擎，无中间框架层
- MNN int8 量化模型，CPU 4 线程，low precision 运行时
- EmbeddingGemma-2 多模态嵌入模型（768 维，Google）

## 构建与运行

1. 环境要求：DevEco Studio（API 26 SDK）、JDK 21
2. **模型权重**（必需）：GitHub 单文件限 100MB，以下文件未入库，构建前需放置到 `entry/src/main/resources/rawfile/eg2v_int8/`：

   | 文件 | 大小 |
   |------|------|
   | `embedding.mnn.weight` | 156 MB |
   | `visual.mnn.weight` | 215 MB |
   | `embeddings_bf16.bin` | 256 MB |

   同目录其余文件（`*.mnn`、`tokenizer.mtok`、`config.json` 等）均已入库。也可以不走打包：在 PC 上执行 `python -m http.server 8000`，将 `Index.ets` 中的 `baseUrl` 改为 PC 的局域网地址，应用内会出现 HTTP 下载入口（手机与 PC 需在同一网络）。

3. 构建与安装：

   ```bash
   hvigorw assembleHap --mode module -p product=default
   hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
   hdc shell aa start -a EntryAbility -b com.example.semsearch
   ```

   含权重 HAP 约 655 MB，首启从 rawfile 流式恢复模型到沙箱，之后无需重复拷贝。

## 工程结构

```
entry/src/main/
├── cpp/                    # NAPI 封装 MNN 推理（embedding_napi.cpp → libentry.so）
├── ets/
│   ├── pages/
│   │   ├── Index.ets       # 介绍页：模型卡、rawfile 恢复进度、Try it
│   │   └── Album.ets       # 落地页 / 搜索 / 详情 / 图搜图 / 聚类（单页状态机）
│   └── common/
│       ├── MnnGate.ets     # 推理并发门控
│       ├── EmbedTasks.ets  # taskpool 任务：init / imgEmbed / visualInit
│       ├── RawInstaller.ets# rawfile → 沙箱流式恢复
│       ├── PhotoIndexManager.ets  # 索引、向量库、聚类、增量同步
│       └── ThumbCache.ets  # 全局缩略图缓存
└── resources/
    ├── base|dark/element/color.json  # M3 双主题色板
    └── rawfile/            # 模型 + 21 张示例照片
```

## 许可

代码以 [Apache-2.0](LICENSE) 许可发布。第三方组件权利归各自所有者：MNN（Apache-2.0）、EmbeddingGemma-2（[Gemma Terms of Use](https://ai.google.dev/gemma/terms)）、AI Edge Gallery（Apache-2.0，UI 参照），详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 相关链接

- [Google AI Edge Gallery](https://github.com/google-ai-edge/gallery) — UI 参照的原版实现
- [MNN](https://github.com/alibaba/MNN) — 端侧推理框架
- [EmbeddingGemma 2](https://developers.googleblog.com/google-ai-edge-with-embeddinggemma-2/) — 多模态嵌入模型
- [HarmonyOS 开发者文档](https://developer.huawei.com/consumer/cn/)
