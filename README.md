# 惠窗中小学端 (huichuang_basic)

[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey.svg)](LICENSE)

国家中小学智慧教育平台（basic.smartedu.cn）的**非官方**第三方客户端，基于 Flutter 构建，覆盖 macOS / Windows / Linux / Android / iOS。

## ✨ 功能

- **课程教学**：学段 → 年级 → 学科 → 版本 → 册次 → 新旧教材 六级目录浏览，章节树 + 课时列表
- **视频播放**：基于 mpv（media_kit）的原生管线播放加密 HLS。本地鉴权代理注入令牌、协商密钥，CDN 节点故障时自动切换——解决官方网页端"视频打不开"的老大难问题
  - 桌面级播放控件：进度/缓冲条、±10s、倍速、音量、全屏、键盘快捷键（空格/K/←→/↑↓/F/M/Esc）、触摸手势（双击全屏、横拖快进、竖拖音量）
  - 断点续播：观看进度自动记录，超过 30s 的课时打开即续播
  - 多课时课程自动拆分为课时列表：旧教材按 bkks 标签，新教材（无标签）按资源排列顺序推导；课内点击即切换，无需返回目录。单课时课程同样以课时列表呈现（条目即课程本身）
- **电子教材**：PDF 在线阅读，自动记忆阅读页码，支持滑条跳页
- **课时文档预览**：课程包内的课件 / 教学设计 / 学习任务单 / 课后练习均为内嵌 PDF，点击即在应用内预览（自动跳过平台的转码目录与白板元数据，直取 PDF 本体），无需下载
- **本地搜索**：教材 / 课程材料 / 课时三级本地检索（平台远程搜索接口有 WAF 指纹拦截，无法在第三方客户端调用；提供"在浏览器打开官方搜索"兜底）
- **账号登录**：软件内 WebView 登录官方页面（与 PiliPlus 相同的交互模式），完成滑动验证后自动捕获令牌并滚动续期（约 7 天），无需反复登录
- **生物识别保险库**（Android / iOS / macOS）：开启后，读取或保存登录密码都需先通过系统生物识别验证；**绝不**在启动时强制验证
- **自适应界面**：≥1000px 导航栏（桌面）→ <600px 底部标签栏（手机），Material 3 + 中英双语

## 🔧 从源码构建

项目通过 [fvm](https://fvm.app) 锁定 Flutter 版本（见仓库根 `.fvmrc`，CI 同步读取该文件）：

```bash
brew install fvm            # 或 dart pub global activate fvm
fvm install                 # 安装 .fvmrc 锁定的 SDK
fvm flutter pub get
fvm flutter run -d macos    # 或 -d windows / -d linux / android / ios
```

之后所有 `flutter` / `dart` 命令一律加 `fvm` 前缀（如 `fvm flutter test`、`fvm flutter build macos`）。

| 平台 | 构建命令 | 验证状态 |
|---|---|---|
| macOS | `flutter build macos` | ✅ 已实测（播放 / PDF / 登录链路） |
| Android | `flutter build apk --release` | ✅ 已构建 |
| iOS | `flutter build ios --no-codesign` | ✅ 已编译（无真机验证） |
| Windows | `flutter build windows` | ⚠️ 仅代码路径审查，未在 Windows 实机验证 |
| Linux | `flutter build linux` | ⚠️ 仅代码路径审查，未在 Linux 实机验证 |

### macOS 说明

- 播放与令牌存储使用 Keychain，**Debug 构建需要有效签名身份**（Apple Development 证书 + 开发团队），否则会遇到 Keychain -34018 错误。无付费开发者账号时，可在 Xcode 中登录个人免费 Apple ID 并选择其 Development 证书。
- 应用已配置 `keychain-access-groups` 为空数组以启用自定义签名下的 Keychain。

### Android 说明

- 生物识别需要设备支持（无指纹/Face 的设备自动隐藏该开关）。
- minSdk 24（Android 7.0）以上。

### 桌面端自动构建（CI）

仓库提供 GitHub Actions 工作流 `desktop-build`，产出三平台 Release 压缩包（macOS arm64 / Linux x64 / Windows x64，文件名含版本号）：

- **手动触发**：仓库页 Actions → desktop-build → Run workflow（产物在本次 run 的 Artifacts 里下载）。
- **发布 Release 时触发**：压缩包自动挂到该 Release 的 Assets 下。
- 不会随 push / commit 自动运行——三平台全量构建开销大，按钮即用。
- 注意：CI 的 macOS 产物为 ad-hoc 签名（可正常打开），但 Keychain 条目不跨签名身份保留；如需凭据保险库长期可靠，请按上文本地签名构建。

## ⚖️ 法律风险规避（务必阅读）

本项目为**个人学习研究用途**的非官方客户端，与教育部"国家中小学智慧教育平台"及其运营方**无任何关联**。使用前请知悉：

1. **非官方、非商业**：本项目以 CC BY-NC-SA 4.0 发布，**禁止任何商业使用**。平台上的课程、教材等一切内容版权归原权利人所有，本项目不存储、不分发任何课程内容，仅在用户本人授权下代理访问其已有权限的资源。
2. **用户协议**：使用第三方客户端访问平台可能不符合平台用户协议的相关条款，由此产生的账号风险（如限制）由使用者自行承担。
3. **数据安全**：所有凭据仅保存在本机系统安全存储（Keychain / Keystore / Secure Storage）中，绝不上传。请勿在不可信设备上登录。
4. **学习用途**：本项目目的是修复官方网页端视频播放体验并方便离线学习个人已授权课程。请尊重平台与授课教师的劳动成果，不得录制、二次分发课程内容。
5. **侵权处理**：若本项目侵犯了任何权利人的合法权益，请提交 Issue，我们将在核实后第一时间处理。
6. **免责声明**：本项目按"现状"提供，不提供任何明示或默示的担保。使用者因使用本项目产生的任何直接或间接损失，项目贡献者不承担责任。

平台接口如有变更导致功能失效，本项目无义务保证及时修复。

## 🙏 致谢

- [PiliPlus](https://github.com/bilibili/PiliPlus) — 播放器选型（media_kit/mpv）与登录交互模式
- [tchMaterial-parser](https://github.com/happycola233/tchMaterial-parser)（MIT）— 电子教材
  `.pkg` 内嵌 PDF 端点、`ebook_mapping` + 目录树接口与多种资源详情端点的发现与整理

## 📄 许可

代码与文档以 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/deed.zh) 许可发布：署名 — 非商业性使用 — 相同方式共享。
