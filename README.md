# itchPocket

一个基于 SwiftUI 的 iOS itch.io 第三方客户端。

## 当前功能

- 发现：搜索游戏，并浏览 itch.io 的游戏分类页面
- 游戏库：展示配置的 itch.io 游戏合集
- 游戏详情：读取游戏介绍、开发者和封面，并可打开 itch.io 原始页面
- 我的：itch.io OAuth 登录与账号信息
- 使用 SwiftUI 构建，支持 iOS 18.0 及以上版本
- GitHub Actions 自动构建 iOS 真机版本并打包构建产物

本项目不提供游戏文件下载、下载队列或本地文件管理功能。

## V4 数据库方向

V4 采用全新数据库初始化，不导入 V3 的旧缓存、个人收藏、日历、更新监控或旧登录状态。首次使用 V4 时，用户需要重新登录 itch 和 Patreon，并通过联网重新建立可恢复的数据。

V3 数据库在 V4 正式启动后的短期安全观察期内保持原样，不参与 V4 初始化；观察期结束后，只有在清理流程、版本回退策略和验收测试完成后才允许删除。

当前开发状态：已加入独立的 V4FreshStoreBootstrap，负责在隔离暂存目录创建空 V4 数据库、关闭后执行 SQLite 完整性检查，并通过同卷目录移动原子提升；无效的现有 V4 目录会被隔离保留。**生产 App 仍使用 V3，尚未切换启动入口。**

账号安全仍然要求：itch 账号使用稳定数字 ID 隔离；OAuth Token 只保存在 Keychain；Patreon 作为独立身份重新登录；异步请求必须验证账号会话代次。

详细方案见 docs/V4_FRESH_DATABASE_STRATEGY.md。

## 环境要求

- Xcode 26 或更新版本
- iOS Deployment Target：18.0
- XcodeGen（brew install xcodegen）

## 本地构建

```bash
xcodegen generate
xcodebuild -project itchPocket.xcodeproj \
  -scheme itchPocket \
  -destination 'generic/platform=iOS Simulator' build
```

## 项目结构

```text
Sources/
  App/
    itchPocketApp.swift
  Views/
    ContentView.swift
    DiscoverView.swift
    GameDetailView.swift
    LibraryView.swift
    ProfileView.swift
  Services/
    ItchAPI.swift
    ItchAuthService.swift
    KeychainStore.swift
    PKCE.swift
    V4FreshStoreBootstrap.swift
```
