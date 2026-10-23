# Third-Party Notices

本仓库（SemSearch）的源代码以 Apache-2.0 许可发布（见 [LICENSE](LICENSE)）。仓库构建和运行涉及以下第三方组件，其权利归各自所有者，并遵循其各自原始许可：

## MNN（Alibaba）

- 用途：端侧深度学习推理框架。本仓库以源码引用方式使用其头文件（`entry/src/main/cpp/include/MNN/`），以预编译静态库方式分发 `libMNN.a`（`entry/src/main/cpp/libs/`）。
- 许可：Apache License 2.0 — https://github.com/alibaba/MNN/blob/master/LICENSE
- 版权所有：Copyright (c) Alibaba, Inc. and its affiliates.

## EmbeddingGemma-2（Google）

- 用途：多模态嵌入模型（768 维），为本应用语义检索能力的核心。模型权重文件**不在本仓库内**（见 [README.md](README.md)「模型权重」章节）。
- 许可：Gemma Terms of Use — https://ai.google.dev/gemma/terms
- 版权所有：Copyright (c) Google LLC.
- 附加说明：使用、复制、分发或修改模型权重须遵守 Gemma Terms of Use；本仓库仅提供加载与使用该模型的工程代码。

## Google AI Edge Gallery

- 用途：本应用的 UI 交互流程（Smart Album：落地页、搜索、详情、图搜图、聚类、Material 3 风格）在设计上参照了 Google AI Edge Gallery 开源实现。
- 许可：Apache License 2.0 — https://github.com/google-ai-edge/gallery/blob/main/LICENSE
- 版权所有：Copyright (c) Google LLC.

## HarmonyOS / OpenHarmony SDK

- 用途：应用运行平台（ArkTS/ArkUI 框架、NAPI 等），通过 DevEco Studio SDK 引入，不在本仓库内分发。
- 许可：OpenHarmony 采用 Apache License 2.0 及其它许可 — https://www.openharmony.io/mainlab/zh-cn/protection/
