# 惠窗中小学端 (huichuang_basic)

[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey.svg)](LICENSE)

国家中小学智慧教育平台（basic.smartedu.cn）的**非官方**第三方客户端，基于 Flutter 构建，覆盖 macOS / Windows / Linux / Android / iOS。

> **惠**民之**窗**，一眼看尽基础教育优质课程。

## ✨ 功能

- **课程教学**：学段 → 年级 → 学科 → 版本 → 册次 → 新旧教材 六级目录浏览，章节树 + 课时列表
- **视频播放**：基于 mpv（media_kit）的原生管线播放加密 HLS，通过本地鉴权代理注入令牌、自动完成密钥协商、CDN 节点故障转移——解决官方网页端"视频打不开"的老大难问题
  - 桌面级播放控件：进度/缓冲条、±10s、倍速、音量、全屏、键盘快捷键（空格/K/←→/↑↓/F/M/Esc）、触摸手势（双击全屏、横拖快进、竖拖音量）
  - 断点续播：观看进度自动记录，超过 30s 的课时打开即续播
- **电子教材**：PDF 教材在线阅读，自动记忆阅读页码，支持页码跳转滑条
- **本地搜索**：教材 / 课程材料 / 课时三级本地检索（平台远程搜索接口有 WAF 指纹拦截，无法在第三方客户端调用；提供"在浏览器打开官方搜索"兜底）
- **账号登录**：软件内 WebView 登录官方页面（与 PiliPlus 相同的交互模式），用户完成滑动验证后自动捕获令牌；令牌自动续期（约 7 天滚动刷新），无需反复登录
- **生物识别保险库**（Android / iOS / macOS）：开启后，已保存的密码在读取时需通过系统生物识别解锁；**绝不**在启动时强制验证
- **自适应界面**：≥1000px 导航栏（桌面）→ <600px 底部标签栏（手机），Material 3 + 中英双语

## 🔧 从源码构建

```bash
flutter pub get
flutter run -d macos      # 或 -d windows / -d linux / android / ios
```

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

- [PiliPlus](https://github.com/bilibili/PiliPlus) — 播放器选型（media_kit/mpv）与登录交互模式的先例
- [tchMaterial-parser](https://github.com/xtwxd/tchMaterial-parser)（MIT）— 电子教材 PDF 端点的发现

## 📄 许可

代码与文档以 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/deed.zh) 许可发布：署名 — 非商业性使用 — 相同方式共享。
