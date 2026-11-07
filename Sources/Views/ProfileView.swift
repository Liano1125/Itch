import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var auth: ItchAuthService
    @EnvironmentObject private var library: PersonalLibraryStore
    @StateObject private var patreon = PatreonAccountService.shared
    @AppStorage("itchPocket.appearance") private var appearanceMode = "light"
    @AppStorage("itchPocket.launchTab") private var launchTab = "discover"

    private let accent = Color(red: 0.94, green: 0.31, blue: 0.34)

    private static let accountDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    accountCard
                    accountServicesSection
                    personalStatsSection

                    if let error = auth.errorMessage {
                        Label {
                            Text(error)
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                    }

                    settingsSection
                    aboutSection
                }
                .padding(20)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .task { await patreon.restore() }
        }
    }


    private var accountServicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("账户与服务")
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "heart.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color(red: 0.96, green: 0.35, blue: 0.48))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Patreon")
                            .font(.headline)
                        Text(patreon.account == nil ? "连接创作者账户，同步授权范围内的账户资料" : "已连接 Patreon 账户")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(patreon.account == nil ? Color.secondary.opacity(0.4) : Color.green)
                        .frame(width: 8, height: 8)
                }

                if let account = patreon.account {
                    HStack(spacing: 12) {
                        CachedRemoteImage(url: account.imageURL, contentMode: .fill) {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.name ?? "Patreon 用户")
                                .font(.subheadline.weight(.semibold))
                            Text("Patreon ID：\(account.userID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let profileURL = account.profileURL {
                            Link(destination: profileURL) {
                                Image(systemName: "arrow.up.right")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }

                    Button(role: .destructive) {
                        Task { await patreon.disconnect() }
                    } label: {
                        Label("断开 Patreon 连接", systemImage: "xmark.circle")
                            .font(.subheadline.weight(.medium))
                    }
                } else {
                    Button {
                        Task { await patreon.connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if patreon.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Label("连接 Patreon 账户", systemImage: "link")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 13)
                        .background(Color(red: 0.96, green: 0.35, blue: 0.48),
                                    in: RoundedRectangle(cornerRadius: 13))
                    }
                    .disabled(patreon.isLoading)
                }

                if let error = patreon.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var personalStatsSection: some View {
        let total = library.records.count
        let favorites = library.records.filter(\.isFavorite).count
        let playing = library.records.filter { $0.status == .playing }.count
        let recentRecords = Array(library.records.sorted { $0.addedAt > $1.addedAt }.prefix(3))

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("游戏档案")
                    .font(.title3.bold())
                Spacer()
                Text("仅统计本机个人游戏库")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                statCard(title: "收藏游戏", value: favorites, symbol: "heart.fill", tint: accent)
                statCard(title: "在玩", value: playing, symbol: "gamecontroller.fill", tint: .green)
            }

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("游戏进度")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(total) 款游戏")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                ForEach(LibraryStatus.allCases) { status in
                    let count = library.records.filter { $0.status == status }.count
                    VStack(spacing: 6) {
                        HStack {
                            Label(status.rawValue, systemImage: status.symbol)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(count)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: total == 0 ? 0 : Double(count) / Double(total))
                            .tint(statusTint(for: status))
                    }
                }
            }
            .padding(15)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if !recentRecords.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("最近加入")
                        .font(.subheadline.weight(.semibold))

                    ForEach(recentRecords) { record in
                        HStack(spacing: 10) {
                            Image(systemName: "gamecontroller.fill")
                                .font(.subheadline)
                                .foregroundStyle(accent)
                                .frame(width: 34, height: 34)
                                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(record.status.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(record.addedAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(15)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func statCard(title: String, value: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(value)")
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func statusTint(for status: LibraryStatus) -> Color {
        switch status {
        case .wishlist: return .blue
        case .playing: return .green
        case .completed: return accent
        case .onHold: return .orange
        case .dropped: return .secondary
        }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("ITCH.IO ACCOUNT")
                    .font(.caption.weight(.heavy))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)

                Spacer()

                Circle()
                    .fill(auth.user == nil ? Color.secondary.opacity(0.5) : Color.green)
                    .frame(width: 7, height: 7)

                Text(auth.user == nil ? "未连接" : "已连接")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let user = auth.user {
                HStack(spacing: 14) {
                    CachedRemoteImage(url: user.coverUrl, contentMode: .fill) {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 62, height: 62)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 5) {
                        Text(user.displayName ?? user.username)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Text("@\(user.username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                HStack(spacing: 8) {
                    Label("账户创建时间", systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(user.accountCreatedAt.map { Self.accountDateFormatter.string(from: $0) } ?? "暂未读取")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(user.accountCreatedAt == nil ? .tertiary : .primary)
                }

                if let url = user.url {
                    Link(destination: url) {
                        Label("打开 itch.io 个人主页", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                }

                Button(role: .destructive) {
                    Task { await auth.signOut() }
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 2)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("连接你的 itch.io 账号")
                            .font(.headline)
                        Text("登录后可读取账号资料与公开合集")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await auth.signIn() }
                } label: {
                    HStack {
                        Spacer()
                        if auth.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Label("使用 itch.io 登录", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 14)
                    .background(accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(auth.isLoading)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("偏好设置")
                .font(.title3.bold())

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.headline)
                            .foregroundStyle(accent)
                            .frame(width: 30)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("外观模式")
                                .font(.subheadline.weight(.semibold))
                            Text("选择你喜欢的界面风格")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Picker("外观模式", selection: $appearanceMode) {
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("外观模式")

                    Divider().padding(.leading, 54)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.stack")
                                .font(.headline)
                                .foregroundStyle(accent)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("启动默认页面")
                                    .font(.subheadline.weight(.semibold))
                                Text("选择每次打开 itchPocket 时首先显示的页面")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        Picker("启动默认页面", selection: $launchTab) {
                            Text("发现").tag("discover")
                            Text("游戏库").tag("library")
                            Text("日历").tag("calendar")
                            Text("我的").tag("profile")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("启动默认页面")
                    }
                    .padding(.vertical, 13)
                }
                .padding(.vertical, 13)

                Divider().padding(.leading, 54)
                NavigationLink {
                    TranslationSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "character.bubble")
                            .font(.headline)
                            .foregroundStyle(accent)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("翻译设置").font(.subheadline.weight(.semibold))
                            Text("选择 Google、DeepSeek 或自定义 AI API").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 54)
                NavigationLink {
                    SparkSyncView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.headline)
                            .foregroundStyle(accent)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Spark 游玩记录").font(.subheadline.weight(.semibold))
                            Text("读取快捷指令同步的 Ren'Py 正式存档").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 54)
                NavigationLink {
                    CacheManagementView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "internaldrive")
                            .font(.headline)
                            .foregroundStyle(accent)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("缓存管理").font(.subheadline.weight(.semibold))
                            Text("查看占用并清理可重新生成的数据").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 54)
                settingsRow("隐私与数据", subtitle: "了解 itchPocket 如何使用数据", symbol: "hand.raised")
            }
            .padding(.horizontal, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关于")
                .font(.title3.bold())

            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 4) {
                    Text("itchPocket")
                        .font(.subheadline.weight(.semibold))
                    Text("为独立游戏爱好者打造的 iOS 客户端")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func settingsRow(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 13)
    }
}
