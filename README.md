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

## 环境要求

- Xcode 26 或更新版本
- iOS Deployment Target：18.0
- XcodeGen（`brew install xcodegen`）

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
```
