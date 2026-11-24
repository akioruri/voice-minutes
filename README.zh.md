# 语音纪要 · Voice Minutes

[English](README.md) | 中文文档

把会议录音变成可检索的文字稿与会议纪要：录制 → 转写 → 打点 → AI 纪要与重点解析，
并在你的设备之间通过 iCloud 同步。支持 macOS 与 iOS。

## 功能

- **录音**：暂停/继续、静音自动分块；录音文件保存在本地沙盒。
- **转写**：Apple 设备端 Speech（离线、带时间戳）或自定义云端 AI 转写。
- **打点标记**：录制中一键标记重点时刻，标记体现在逐字稿中；可自动对标记处内容
  发起 AI 解析（默认开启，提示词可改）。
- **重点内容块**：手动新增（按钮 / Cmd+Enter）或从时间标记转化；每块独立，可单独
  调用 LLM 解析；手动录入与自动生成内容有区分。
- **会议纪要**：一键生成/重新生成；提示词库支持多条自定义提示词、全局默认与按
  文件夹指定默认，还可让 AI 基于描述自动生成提示词（含标题）。
- **导出**：Markdown、SRT 字幕、PDF。
- **iCloud 同步**：文件夹、纪要、逐字稿、重点内容跨设备同步；录音按需下载（点击
  播放时），节省 iCloud 空间。
- **多语言界面**：简体中文 / English / 日本語；AI 输出语言跟随界面语言。

## 环境要求

- macOS 26 / iOS 26 及以上
- 从源码构建需要 Xcode 27

## 安装

- **TestFlight**（推荐）：通过开发者提供的邀请链接安装，macOS 与 iOS 均经 TF
  分发。
- **从源码构建**：`open voice-minutes.xcodeproj`，在 Xcode 中 Cmd+R 运行。

## 使用提示

1. 设置 → **模型**：选择转写/纪要服务商并填入 API Key（仅存本机钥匙串），或启用
   Apple 设备端转写。
2. 设置 → **解析**：调整重点解析与打点解析提示词；设置 → **提示词**：管理会议
   纪要提示词库。
3. 设置 → **通用**：开启「通过 iCloud 同步」。**所有设备需登录同一个 iCloud
   账号**才能互通；TestFlight 包使用 CloudKit 生产环境。
4. 录音结束后在详情页查看逐字稿、打点与重点块，按需生成纪要或导出。

## 隐私

- 录音与文字稿默认只存在于本机沙盒；开启同步后进入**你自己 iCloud 账号的私有
  数据库**，开发者无法访问。
- API Key 仅存于各设备钥匙串，不参与同步。
- 转写/纪要请求只发往你自己配置的服务商；无分析、无埋点。

## 开发

仓库约定、同步架构与分发流程见 [AGENTS.md](AGENTS.md)。

```bash
# 打 TestFlight 包（随后在 Organizer 中 Distribute App）
xcodebuild -project voice-minutes.xcodeproj -scheme voice-minutes \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath ~/Library/Developer/Xcode/Archives/Mac.xcarchive \
  -allowProvisioningUpdates archive
```

- 界面字符串走 `InterfaceLanguage.text("key")`，新增 key 需同步三份
  `Localizable.strings`。
- 每次上传 TestFlight 前递增 `CURRENT_PROJECT_VERSION`。
- 同步问题诊断：设置 → 通用 的状态详情行，或
  `/usr/bin/log show --predicate 'subsystem == "com.akioruri.voiceminutes"'`。
