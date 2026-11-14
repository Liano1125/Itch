import SwiftUI
import WebKit
import Foundation

// MARK: - Models

private struct GamePagePayload: Decodable {
    /// Confirms page identity only; it does not imply every detail section was parsed.
    let isCompleteSnapshot: Bool?
    let ageGateRequired: Bool?
    let description: String?
    let descriptionResolved: Bool?
    let developer: String?
    let coverURL: URL?
    let galleryURLs: [URL]?
    let galleryResolved: Bool?
    let authorURL: URL?
    let authorAvatarURL: URL?
    let patreonURL: URL?
    let discordURL: URL?
    let discoveryTags: [LibraryDiscoveryTag]?
    let tagsResolved: Bool?
    let engine: String?
    let scriptError: String?
}

private struct GameDetailPayload {
    let description: String?
    let descriptionResolved: Bool
    let developer: String?
    let coverURL: URL?
    let galleryURLs: [URL]
    let galleryResolved: Bool
    let authorURL: URL?
    let authorAvatarURL: URL?
    let patreonURL: URL?
    let discordURL: URL?
    let discoveryTags: [LibraryDiscoveryTag]
    let tagsResolved: Bool
    let engine: String?

    var requiredDetailResolved: Bool {
        GameDetailSnapshotPolicy.hasRequiredDescription(descriptionResolved: descriptionResolved)
    }
}

enum GameDetailParserProfile: String {
    case standard
    case adultRenPy
    case adult3D

    var descriptionSelectors: [String] {
        let common = [
            ".formatted_description", ".game_description", "#game_description",
            ".game_page_content", ".game_page_text", "#description", ".description",
            "[itemprop='description']", "[data-game-description]"
        ]
        switch self {
        case .standard:
            return common
        case .adultRenPy:
            return [
                ".formatted_description", ".game_description", "#game_description",
                ".game_page_content", ".game_page_text", "#description",
                "[itemprop='description']", "[data-game-description]",
                ".formatted_description .paragraph", ".game_description .paragraph"
            ]
        case .adult3D:
            return [
                ".game_page_content", ".game_page_text", ".formatted_description",
                ".game_description", "#game_description", "#description",
                "[itemprop='description']", "[data-game-description]",
                ".game_page_content .formatted_description",
                ".game_page_content .game_description"
            ]
        }
    }

    var galleryContainerSelectors: [String] {
        [
            ".screenshot_list", ".screenshot_container", ".game_page_screenshots",
            "#game_screenshots", ".screenshot"
        ]
    }

    // Keep the gallery scoped to itch.io's dedicated screenshot/lightbox markup.
    // Description images are intentionally excluded: creators often place Discord,
    // Patreon and other social-promo banners in the description body.
    var galleryImageSelectors: [String] {
        [
            "img.screenshot", ".screenshot_list img", ".screenshot_container img",
            ".screenshot img", "#game_screenshots img", ".game_page_screenshots img"
        ]
    }

    var galleryAnchorSelectors: [String] {
        [
            ".screenshot_list a", ".screenshot_container a", ".screenshot a",
            "#game_screenshots a", ".game_page_screenshots a",
            "a[data-image_lightbox]"
        ]
    }
}

// MARK: - Game Detail View

struct GameDetailView: View {
    let game: PublicCollectionGame
    let parserProfile: GameDetailParserProfile

    init(game: PublicCollectionGame, parserProfile: GameDetailParserProfile = .standard) {
        self.game = game
        self.parserProfile = parserProfile
    }

    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var library: PersonalLibraryStore
    @EnvironmentObject private var gameCalendar: GameCalendarStore
    @EnvironmentObject private var updateMonitor: GameUpdateMonitorStore

    private var developerRepository: DeveloperRepository {
        DeveloperRepository(database: .shared)
    }

    private var gameRepository: GameRepository {
        GameRepository(database: .shared)
    }

    @State private var detail: GameDetailPayload?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reloadToken = UUID()
    @State private var translatedDescription: String?
    @State private var cachedOriginalDescription: String?
    @State private var hasLoadedCompleteDetailSnapshot = false
    @State private var translatedUpdates: [String: String] = [:]
    @State private var translationStatus: String?
    @State private var showingOriginalDescription = false
    @State private var isRefreshingTranslation = false
    @State private var selectedGalleryIndex = 0
    @State private var showingGalleryViewer = false
    @State private var cachedGalleryURLs: [URL] = []
    @State private var resolvedAuthorAvatarURL: URL?

    private var galleryImages: [URL] {
        if let detail { return detail.galleryURLs }
        return cachedGalleryURLs
    }

    private var galleryCacheKey: String {
        "itchPocket.gallery.v1.\(game.id)"
    }

    private var displayCover: URL? {
        detail?.coverURL ?? game.coverURL
    }

    private var displayDeveloper: String? {
        detail?.developer ?? game.developer
    }

    private var displayDescription: String? {
        GameDetailSnapshotPolicy.displayedDescription(
            current: detail?.description,
            cached: cachedOriginalDescription,
            fallback: game.description
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                gallerySection
                titleSection
                authorSection
                linksSection

                Divider()

                descriptionSection
                engineSection
                sparkPlaySection
                statusHistorySection
                gameUpdateHistorySection

                if let errorMessage {
                    errorSection(errorMessage)
                }

                originalPageButton
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(uiColor: .systemBackground))
        .task(id: game.id) {
            await loadCachedDescription()
        }
        .task(id: "devlogs:\(game.id)") {
            await syncMissingHistoricalDevlogs()
        }
        .task(id: detail == nil ? nil : (detail?.authorURL?.absoluteString ?? game.url?.absoluteString)) {
            guard detail != nil else { return }
            let resolved = await PatreonAvatarService.shared.avatarURL(
                authorURL: detail?.authorURL,
                gameURL: game.url
            )
            let record = library.record(for: game.id)
            resolvedAuthorAvatarURL = resolved ?? detail?.authorAvatarURL
            if var updated = record {
                var changed = false
                if let authorURL = detail?.authorURL,
                   updated.developerProfileURL != authorURL.absoluteString {
                    updated.developerProfileURL = authorURL.absoluteString
                    changed = true
                }
                if changed { library.update(updated) }
            }
        }
        .navigationTitle("游戏详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: reloadDetail) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .sheet(isPresented: $showingGalleryViewer) {
            galleryViewer
                .presentationBackground(Color.black)
        }
        .overlay {
            GeometryReader { proxy in
                DetailPageReader(
                    url: game.url,
                    profile: parserProfile,
                    reloadToken: reloadToken,
                    onLoad: handleLoadedDetail,
                    onError: handleLoadError
                )
                // A 1x1 hidden WebView changes itch.io's responsive DOM and can
                // prevent viewport-triggered lazy images from loading.
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Cover

    private var coverSection: some View {
        GeometryReader { geometry in
            ZStack {
                if let url = displayCover {
                    CachedRemoteImage(url: url, contentMode: .fill) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(.quaternary)
                            ProgressView()
                        }
                    }
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                    .clipped()
                } else {
                    coverPlaceholder
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height
            )
            .clipped()
        }
        .aspectRatio(1.45, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var coverPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.quaternary)

            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Gallery

    @ViewBuilder
    private var gallerySection: some View {
        let images = galleryImages

        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("游戏图库").font(.headline)
                Spacer()
                if !images.isEmpty {
                    Text("\(images.count) 张")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isLoading {
                    Text("加载中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if errorMessage != nil {
                    Text("读取失败")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    if images.isEmpty {
                        galleryPlaceholder(
                            message: isLoading
                                ? "正在加载游戏截图"
                                : (errorMessage == nil ? "暂未获取到游戏截图" : "详情读取失败，请重新读取")
                        )
                    } else {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, url in
                            Button {
                                selectedGalleryIndex = index
                                showingGalleryViewer = true
                            } label: {
                                CachedRemoteImage(url: url, contentMode: .fill) {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(uiColor: .tertiarySystemFill))
                                        .overlay { ProgressView() }
                                }
                                .frame(width: 310, height: 174)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func galleryPlaceholder(message: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                VStack(spacing: 9) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: errorMessage == nil ? "photo.on.rectangle.angled" : "exclamationmark.arrow.circlepath")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 310, height: 174)
    }

    private var galleryViewer: some View {
        NavigationStack {
            TabView(selection: $selectedGalleryIndex) {
                ForEach(Array(galleryImages.enumerated()), id: \.offset) { index, url in
                    CachedRemoteImage(url: url, contentMode: .fit) {
                        ProgressView()
                    }
                    .tag(index)
                    .background(Color.black)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .background(Color.black.ignoresSafeArea())
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showingGalleryViewer = false }
                        .foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(game.title)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)

            if !game.platforms.isEmpty {
                HStack(spacing: 7) {
                    ForEach(game.platforms, id: \.self) { platform in
                        Text(platform)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Author and Links

    @ViewBuilder
    private var authorSection: some View {
        if let developer = displayDeveloper, !developer.isEmpty {
            NavigationLink {
                if let url = detail?.authorURL {
                    AuthorProfileView(name: developer, url: url)
                } else if let url = game.url {
                    AuthorProfileView(name: developer, url: url)
                }
            } label: {
                HStack(spacing: 10) {
                    CachedRemoteImage(
                        url: resolvedAuthorAvatarURL ?? detail?.authorAvatarURL,
                        contentMode: .fill
                    ) {
                        Image(systemName: "person.fill")
                            .resizable().scaledToFit().padding(11)
                            .foregroundStyle(.secondary)
                            .background(Color(uiColor: .tertiarySystemFill))
                    }
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())
                    Text(developer)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var linksSection: some View {
        let record = library.record(for: game.id)
        let patreon = detail?.patreonURL ?? URL(string: record?.patreonURL ?? "")
        let discord = detail?.discordURL ?? URL(string: record?.discordURL ?? "")
        if patreon != nil || discord != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Link").font(.headline)
                HStack(spacing: 12) {
                    if let patreon {
                        Link(destination: patreon) {
                            HStack(spacing: 9) {
                                PatreonBrandMark()
                                    .frame(width: 23, height: 23)
                                Text("Patreon").font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color(red: 1.0, green: 0.26, blue: 0.31), in: RoundedRectangle(cornerRadius: 13))
                        }
                    }
                    if let discord {
                        Link(destination: discord) {
                            HStack(spacing: 9) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.system(size: 21, weight: .semibold))
                                Text("Discord").font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color(red: 0.345, green: 0.396, blue: 0.949), in: RoundedRectangle(cornerRadius: 13))
                        }
                    }
                }
            }
        }
    }

    private struct PatreonBrandMark: View {
        var body: some View {
            ZStack(alignment: .topLeading) {
                Capsule().frame(width: 5, height: 22).offset(x: 1, y: 1)
                Circle().frame(width: 12, height: 12).offset(x: 10, y: 0)
            }
            .foregroundStyle(.white)
            .frame(width: 23, height: 23)
        }
    }

    // MARK: Description

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("游戏介绍")
                .font(.title2.bold())

            if let description = displayDescription,
               !description.isEmpty {
                Text(showingOriginalDescription ? description : (translatedDescription ?? description))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    if translatedDescription != nil {
                        Button(showingOriginalDescription ? "显示中文译文" : "查看英文原文") {
                            showingOriginalDescription.toggle()
                        }
                        .font(.caption.weight(.medium))
                    }
                    Button(isRefreshingTranslation ? "翻译中…" : "重新翻译") {
                        Task { await translateContent(forceRefresh: true) }
                    }
                    .font(.caption.weight(.medium))
                    .disabled(isRefreshingTranslation || !TranslationService.isConfigured)
                    Spacer(minLength: 0)
                    if let translationStatus {
                        Text(translationStatus).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取游戏介绍…")
                        .foregroundStyle(.secondary)
                }

            } else {
                Text("暂时无法读取游戏介绍。")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Status History

    @ViewBuilder
    private var engineSection: some View {
        let engine = library.record(for: game.id)?.engine ?? detail?.engine
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("游戏引擎")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(engine ?? (detail == nil ? "正在识别…" : "暂未识别"))
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var sparkPlaySection: some View {
        let record = library.record(for: game.id)
        let hasSparkData = record?.sparkPlaytimeSeconds != nil
            || record?.sparkLastSaveAt != nil
            || record?.sparkRenpyVersion != nil
            || record?.sparkSaveCount != nil

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Spark 游玩记录", systemImage: "gamecontroller")
                    .font(.title3.bold())
                Spacer()
                Text(hasSparkData ? "已同步" : "等待同步")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(hasSparkData ? .green : .secondary)
            }

            HStack(spacing: 9) {
                sparkMetric(
                    title: "累计运行时长",
                    value: Self.sparkDuration(record?.sparkPlaytimeSeconds),
                    symbol: "clock"
                )
                sparkMetric(
                    title: "Ren'Py 版本",
                    value: record?.sparkRenpyVersion ?? "暂无记录",
                    symbol: "cpu"
                )
            }
            sparkInfoRow("最近存档", date: record?.sparkLastSaveAt)
            sparkInfoRow(
                "有效存档档位数量",
                value: record?.sparkSaveCount.map { "\($0) 个" } ?? "暂无记录"
            )

            if !hasSparkData {
                Text(record == nil
                    ? "请先将游戏加入游戏库，再同步 Spark 存档。"
                    : "暂未匹配到该游戏的 Spark 存档。请确认 Allsaves 中的游戏文件夹名称，并确保存档已复制完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await SparkSyncStore.shared.rescan(library: library) }
                } label: {
                    Label("立即重新扫描", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func sparkMetric(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11))
    }

    private func sparkInfoRow(_ title: String, date: Date?) -> some View {
        sparkInfoRow(title, value: date.map { Self.sparkDate($0) } ?? "暂无记录")
    }

    private func sparkInfoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private static func sparkDate(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute())
    }

    private static func sparkDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "暂无记录" }
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let remainder = minutes % 60
        return hours > 0 ? "\(hours)小时\(remainder)分钟" : "\(remainder)分钟"
    }

    @ViewBuilder
    private var statusHistorySection: some View {
        if library.record(for: game.id) != nil {
            VStack(alignment: .leading, spacing: 13) {
                Text("状态记录")
                    .font(.title2.bold())

                let events = library.history(for: game.id)
                if events.isEmpty {
                    Text("从现在开始，游戏状态的每次变化都会记录在这里。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: event.toStatus.symbol)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34, height: 34)
                                    .background(Color.accentColor.opacity(0.12), in: Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.fromStatus.map { "\($0.rawValue) → \(event.toStatus.rawValue)" } ?? "加入个人游戏库")
                                        .font(.subheadline.weight(.semibold))
                                    Text(event.changedAt.formatted(date: .long, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: Game Update History

    @ViewBuilder
    private var gameUpdateHistorySection: some View {
        if library.record(for: game.id) != nil {
            let updates = library.updates(for: game.id)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("游戏更新记录")
                        .font(.title2.bold())
                    Spacer()
                    if !updates.isEmpty {
                        Text("\(updates.count) 条")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if updates.isEmpty {
                    Text("检测到的页面更新会同步显示在这里。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(updates) { update in
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                let translated = translatedUpdates[update.id]
                                Text(translated ?? update.title ?? update.summary)
                                    .font(.subheadline.weight(.semibold))
                                if !(update.summary.isEmpty) && update.title != nil {
                                    Text(translated == nil ? update.summary : translated!.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(4)
                                }
                                Text((update.publishedAt ?? update.detectedAt).formatted(date: .long, time: .shortened) + ((update.isHistorical ?? false) ? " · 原始发布日期" : " · 检测时间"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let rawURL = update.url, let postURL = URL(string: rawURL) {
                                    Link("查看 itch.io 更新原文", destination: postURL)
                                        .font(.caption.weight(.medium))
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: Error

    private func errorSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "部分详情读取失败",
                systemImage: "exclamationmark.triangle"
            )
            .font(.subheadline.weight(.medium))

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)

            if message.contains("18+"), let url = game.url {
                NavigationLink {
                    ItchSearchResultsView(query: game.title, customURL: url.absoluteString)
                } label: {
                    Label("在应用内确认 18+ 年龄", systemImage: "checkmark.shield")
                        .font(.subheadline.weight(.medium))
                }
                Text("完成确认后返回此页面，再点击重新读取。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("重新读取", action: reloadDetail)
                .font(.subheadline.weight(.medium))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    // MARK: Original Page

    private var originalPageButton: some View {
        Group {
            if let url = game.url {
                Button {
                    openURL(url)
                } label: {
                    Label(
                        "在 itch.io 查看完整游戏页面",
                        systemImage: "safari"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Data Handling

    private func handleLoadedDetail(_ result: GameDetailPayload) {
        let persistenceStartedAt = Date()
        let existingRecord = library.record(for: game.id)
        let existingGame = try? gameRepository.game(id: game.id)
        let authorURL = result.authorURL ?? URL(string: existingRecord?.developerProfileURL ?? game.developerProfileURL?.absoluteString ?? "")
        let developerID = authorURL.map { DeveloperRepository.canonicalID(for: $0.absoluteString) } ?? existingGame?.developerID
        let existingDeveloper = developerID.flatMap { id in
            try? developerRepository.developer(id: id)
        } ?? nil
        let developerName = GameDetailRepository.resolvedDeveloperName(
            incoming: result.developer,
            existing: existingDeveloper?.name,
            library: game.developer ?? existingRecord?.developer
        )

        do {
            // Create/verify the developer row before assigning its foreign key to the game.
            // If the page gives us neither a usable name nor an existing developer row,
            // keep the relationship nil instead of persisting a dangling reference.
            let safeDeveloperID = GameDeveloperReferencePolicy.resolvedID(
                candidateID: developerID,
                hasUsableName: developerName != nil,
                existingDeveloperExists: existingDeveloper != nil
            )
            if let safeDeveloperID, let developerName {
                try developerRepository.upsertIdentity(
                    id: safeDeveloperID,
                    name: developerName,
                    profileURL: authorURL?.absoluteString,
                    patreonURL: result.patreonURL?.absoluteString,
                    discordURL: result.discordURL?.absoluteString
                )
            }

            try gameRepository.upsertMetadata(
                id: game.id,
                title: game.title,
                gameURL: game.url?.absoluteString,
                coverURL: result.coverURL?.absoluteString ?? game.coverURL?.absoluteString,
                engine: result.engine,
                developerID: safeDeveloperID
            )

            try GameDetailRepository.shared.applyPageSnapshot(
                GameDetailPageSnapshot(
                    description: result.description,
                    descriptionResolved: result.descriptionResolved,
                    galleryURLs: result.galleryURLs.map(\.absoluteString),
                    galleryResolved: result.galleryResolved,
                    discoveryTags: result.discoveryTags,
                    tagsResolved: result.tagsResolved
                ),
                for: game.id
            )

            // Render the values that actually survived persistence. An unresolved
            // section therefore continues to display its previously cached value.
            let persisted = try GameDetailRepository.shared.detail(for: game.id)
            print(String(
                format: "itchPocket detail.performance persistence=%.3fs",
                Date().timeIntervalSince(persistenceStartedAt)
            ))
            let persistedGallery = (persisted?.galleryURLs ?? []).compactMap { URL(string: $0) }
            let resolved = GameDetailPayload(
                description: persisted?.description,
                descriptionResolved: result.descriptionResolved,
                developer: developerName ?? existingDeveloper?.name ?? game.developer,
                coverURL: result.coverURL ?? game.coverURL,
                galleryURLs: persistedGallery,
                galleryResolved: result.galleryResolved,
                authorURL: authorURL,
                authorAvatarURL: result.authorAvatarURL,
                patreonURL: result.patreonURL,
                discordURL: result.discordURL,
                discoveryTags: persisted?.discoveryTags ?? [],
                tagsResolved: result.tagsResolved,
                engine: result.engine
            )
            detail = resolved
            hasLoadedCompleteDetailSnapshot = persisted?.fetchStatus == .complete
            cachedGalleryURLs = persistedGallery
            Task {
                await PersistentImageCache.shared.prefetch(Array(persistedGallery.prefix(6)))
            }

            if var record = library.record(for: game.id) {
                var changed = false
                if let authorURL, record.developerProfileURL != authorURL.absoluteString {
                    record.developerProfileURL = authorURL.absoluteString
                    changed = true
                }
                if let avatarURL = result.authorAvatarURL,
                   record.developerAvatarURL != avatarURL.absoluteString {
                    record.developerAvatarURL = avatarURL.absoluteString
                    changed = true
                }
                if result.tagsResolved && record.discoveryTags != resolved.discoveryTags {
                    record.discoveryTags = resolved.discoveryTags
                    changed = true
                }
                if let engine = result.engine, record.engine != engine {
                    record.engine = engine
                    changed = true
                }
                if let patreonURL = result.patreonURL?.absoluteString,
                   record.patreonURL != patreonURL {
                    record.patreonURL = patreonURL
                    changed = true
                }
                if let discordURL = result.discordURL?.absoluteString,
                   record.discordURL != discordURL {
                    record.discordURL = discordURL
                    changed = true
                }
                if changed { library.update(record) }
            }

            if cachedOriginalDescription != resolved.description {
                translatedDescription = nil
            }
            cachedOriginalDescription = resolved.description
            translatedUpdates = [:]
            translationStatus = nil
            selectedGalleryIndex = 0
            isLoading = false
            errorMessage = result.requiredDetailResolved
                ? nil
                : "页面已识别，但游戏介绍未能确认读取；已保留原有详情资料。"
            Task { await translateContent() }
        } catch {
            // A failed save must never be presented as a successful/complete read.
            isLoading = false
            errorMessage = "详情保存失败，已保留原有缓存：\(error.localizedDescription)"
        }
    }

    private func loadCachedDescription() async {
        if let savedGame = try? gameRepository.game(id: game.id) {
            let developer = savedGame.developerID.flatMap { try? developerRepository.developer(id: $0) }
            let savedDetail = try? GameDetailRepository.shared.detail(for: game.id)
            hasLoadedCompleteDetailSnapshot = savedDetail?.fetchStatus == .complete
            let cachedIsComplete = savedDetail?.fetchStatus == .complete
            let cachedDetail = GameDetailPayload(
                description: savedDetail?.description,
                descriptionResolved: cachedIsComplete,
                developer: developer?.name ?? game.developer,
                coverURL: URL(string: savedGame.coverURL ?? game.coverURL?.absoluteString ?? ""),
                galleryURLs: (savedDetail?.galleryURLs ?? []).compactMap { URL(string: $0) },
                galleryResolved: cachedIsComplete,
                authorURL: URL(string: developer?.profileURL ?? game.developerProfileURL?.absoluteString ?? ""),
                authorAvatarURL: URL(string: developer?.avatarURL ?? ""),
                patreonURL: URL(string: developer?.patreonURL ?? ""),
                discordURL: URL(string: developer?.discordURL ?? ""),
                discoveryTags: savedDetail?.discoveryTags ?? [],
                tagsResolved: cachedIsComplete,
                engine: savedGame.engine
            )
            if cachedDetail.description != nil || cachedDetail.coverURL != nil || !cachedDetail.galleryURLs.isEmpty || hasLoadedCompleteDetailSnapshot {
                detail = cachedDetail
                cachedGalleryURLs = cachedDetail.galleryURLs
                cachedOriginalDescription = cachedDetail.description
                isLoading = false
            }
        }

        let target = AppPreferences.string(forKey: TranslationService.targetKey) ?? "zh-CN"
        for update in library.updates(for: game.id) {
            let scope = "devlog:\(game.id):\(update.id)"
            if let cached = await TranslationCache.shared.latest(scope: scope, target: target) {
                translatedUpdates[update.id] = cached.translation
            }
        }
        let scope = "game-description:\(game.id)"
        guard let cached = await TranslationCache.shared.latest(scope: scope, target: target) else {
            if !translatedUpdates.isEmpty {
                translationStatus = "已显示本地更新译文"
            }
            return
        }
        cachedOriginalDescription = cached.sourceText
        translatedDescription = cached.translation
        translationStatus = "已显示本地译文 · 正在检查更新"
        // Cache is for immediate display only; refresh source and fill missing devlogs.
        await translateContent()
    }

    private func translateContent(forceRefresh: Bool = false) async {
        guard TranslationService.isConfigured else {
            translationStatus = "请在「我的 - 翻译设置」配置翻译服务。"
            return
        }
        guard !isRefreshingTranslation else { return }
        isRefreshingTranslation = true
        defer { isRefreshingTranslation = false }

        translationStatus = forceRefresh ? "正在重新翻译…" : "正在检查本地译文…"
        var usedCache = false
        var failureCount = 0
        var completedUpdates = 0
        let updates = library.updates(for: game.id)
        if let description = displayDescription, !description.isEmpty {
            do {
                let result = try await TranslationService.translateCached(
                    description,
                    scope: "game-description:\(game.id)",
                    forceRefresh: forceRefresh
                )
                translatedDescription = result.text
                usedCache = result.wasCached
            } catch {
                failureCount += 1
            }
        }
        for update in updates {
            let source = [update.title, update.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            guard !source.isEmpty else { continue }
            do {
                let result = try await TranslationService.translateCached(
                    source,
                    scope: "devlog:\(game.id):\(update.id)",
                    forceRefresh: forceRefresh
                )
                translatedUpdates[update.id] = result.text
                usedCache = usedCache || result.wasCached
                completedUpdates += 1
            } catch {
                failureCount += 1
            }
        }
        if failureCount > 0 {
            translationStatus = "已完成 \(completedUpdates)/\(updates.count) 条更新译文，\(failureCount) 项待重试"
        } else {
            translationStatus = usedCache ? "已检查更新 · 已使用本地译文" : "翻译完成 · 已保存"
        }
    }

    private func syncMissingHistoricalDevlogs() async {
        guard let record = library.record(for: game.id) else { return }

        // The global six-hour sync may have run before this game was added.
        // Recheck this game's RSS once when its detail is opened, but avoid
        // repeating successful/empty results on every navigation.
        let hasRecentResult = updateMonitor.lastHistoricalSyncAt.map {
            Date().timeIntervalSince($0) < 12 * 60 * 60
        } == true && updateMonitor.lastHistoricalSyncResults.contains { result in
            result.gameID == game.id
                && !result.message.localizedCaseInsensitiveContains("失败")
                && !result.message.localizedCaseInsensitiveContains("缺少有效")
        }
        guard !hasRecentResult else { return }

        while updateMonitor.isSyncingHistoricalDevlogs {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
        }
        _ = await updateMonitor.syncHistoricalDevlogs(
            records: [record],
            calendarStore: gameCalendar,
            libraryStore: library
        )
    }

    private func handleLoadError(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    private func reloadDetail() {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        // Keep the last successful snapshot visible while the new page loads.
        reloadToken = UUID()
    }
}

// MARK: - Game Page Reader


enum GamePageScript {
    static let source = """
        (() => {
            try {
                const clean = el => {
                    const value = el?.innerText || el?.textContent || "";
                    return value.replace(/[ \\t]+/g, " ").replace(/\\n{3,}/g, "\\n\\n").trim();
                };

                const absolute = value => {
                    try {
                        return value ? new URL(value, location.href).href : null;
                    } catch (_) {
                        return null;
                    }
                };

                const pageURL = new URL(location.href);
                const isItchHost = pageURL.hostname === "itch.io"
                    || pageURL.hostname.endsWith(".itch.io");
                const gameRoot = document.querySelector(
                    ".game_page, .game_page_wrap, main .game_page"
                );
                const titleElement = document.querySelector(
                    ".game_page_title, .game_page h1, h1.game_title, meta[property='og:title']"
                );
                const pageTitle = clean(titleElement)
                    || (document.title || "").replace(/\\s*[|–-]\\s*itch\\.io\\s*$/i, "").trim();
                const hasGameRoot = Boolean(gameRoot);
                const hasGameTitle = pageTitle.length > 0 && pageTitle.toLowerCase() !== "itch.io";
                const bodyText = document.body?.innerText || "";
                // Adult game pages can return an age-gate document at the same
                // one-segment URL as the actual game. Never treat that document
                // as a successfully parsed game snapshot.
                const ageGateRequired = !hasGameRoot
                    && /You must be 18\\+ to view this content|Date of Birth:/i.test(bodyText);
                const pathParts = pageURL.pathname.split("/").filter(Boolean);
                // Adult catalog pages use several description containers depending on
                // the creator's page template. Keep a broad semantic fallback list.
                const parserProfile = "__PARSER_PROFILE__";
                const profileSelectors = {
                    standard: {
                        description: __STANDARD_DESCRIPTION_SELECTORS__,
                        galleryContainers: __STANDARD_GALLERY_CONTAINERS__,
                        galleryImages: __STANDARD_GALLERY_IMAGES__,
                        galleryAnchors: __STANDARD_GALLERY_ANCHORS__
                    },
                    adultRenPy: {
                        description: __RENPY_DESCRIPTION_SELECTORS__,
                        galleryContainers: __RENPY_GALLERY_CONTAINERS__,
                        galleryImages: __RENPY_GALLERY_IMAGES__,
                        galleryAnchors: __RENPY_GALLERY_ANCHORS__
                    },
                    adult3D: {
                        description: __ADULT3D_DESCRIPTION_SELECTORS__,
                        galleryContainers: __ADULT3D_GALLERY_CONTAINERS__,
                        galleryImages: __ADULT3D_GALLERY_IMAGES__,
                        galleryAnchors: __ADULT3D_GALLERY_ANCHORS__
                    }
                };
                const selectedProfile = profileSelectors[parserProfile] || profileSelectors.standard;
                const contentSelector = selectedProfile.description.join(", ");
                const contentRoots = Array.from(document.querySelectorAll(contentSelector));
                const hasGameContent = contentRoots.length > 0;
                // Some valid itch.io layouts omit the historical .game_page wrapper,
                // but must still contain at least one real game-content marker.
                const isCompleteSnapshot = isItchHost
                    && !ageGateRequired
                    // itch.io supports both creator subdomains and canonical
                    // multi-segment game URLs; path depth alone is not page identity.
                    && pathParts.length > 0
                    && hasGameTitle
                    && (hasGameRoot || hasGameContent);

                let description = null;
                let descriptionResolved = false;
                // A comma-separated query returns each matching element once,
                // avoiding the overlapping .game_page_content descendant scan.
                const descriptionElements = contentRoots
                    .sort((left, right) => clean(right).length - clean(left).length);
                for (const element of descriptionElements) {
                    const value = clean(element);
                    if (value.length > 0 && (!description || value.length > description.length)) {
                        description = value;
                        descriptionResolved = true;
                    }
                }

                if (!description) {
                    const descriptionMeta = document.querySelector(
                        'meta[name="description"], meta[property="og:description"]'
                    );
                    const metaDescription = (descriptionMeta?.getAttribute("content") || "").trim();
                    if (metaDescription.length > 0) {
                        // Open Graph/meta text is only a short preview, not proof
                        // that the complete game introduction was extracted.
                        description = metaDescription;
                    }
                }

                let developer = null;
                const developerSelectors = [
                    ".game_author a",
                    ".game_author",
                    ".header_links .user_link",
                    ".user_link"
                ];

                for (const selector of developerSelectors) {
                    const value = clean(document.querySelector(selector));
                    if (value) {
                        developer = value;
                        break;
                    }
                }

                let coverURL = null;
                const coverSelectors = [
                    'meta[property="og:image"]',
                    'meta[name="twitter:image"]',
                    ".game_cover img",
                    ".game_thumb img",
                    ".screenshot img"
                ];

                for (const selector of coverSelectors) {
                    const el = document.querySelector(selector);
                    if (!el) continue;

                    const value = absolute(
                        el.getAttribute("content") ||
                        el.currentSrc ||
                        el.getAttribute("data-lazy_src") ||
                        el.getAttribute("data-lazy-src") ||
                        el.getAttribute("data-src") ||
                        el.getAttribute("src")
                    );

                    if (value) {
                        coverURL = value;
                        break;
                    }
                }

                // itch.io screenshot images are linked to their original-size asset.
                // Read the anchor href first (usually /original/...), then fall back to lazy-loaded img sources.
                const galleryCandidates = [];
                const galleryContainer = document.querySelector(selectedProfile.galleryContainers.join(", "));
                const screenshotAnchors = Array.from(document.querySelectorAll(
                    selectedProfile.galleryAnchors.join(", ")
                ));
                for (const anchor of screenshotAnchors) {
                    const image = anchor.querySelector("img");
                    const href = absolute(anchor.getAttribute("href"));
                    const imageSource = absolute(
                        image?.getAttribute("data-lazy_src") || image?.getAttribute("data-lazy-src") ||
                        image?.getAttribute("data-src") || image?.getAttribute("data-original") ||
                        image?.currentSrc || image?.getAttribute("srcset")?.split(/\\s+/)[0] ||
                        image?.getAttribute("data-srcset")?.split(/\\s+/)[0] || image?.getAttribute("src")
                    );
                    const candidate = href && /img\\.itch\\.zone|\\.(png|jpe?g|webp|gif)(\\?|$)/i.test(href) ? href : imageSource;
                    if (candidate) galleryCandidates.push(candidate);
                }
                const screenshotImages = Array.from(document.querySelectorAll(
                    selectedProfile.galleryImages.join(", ")
                ));
                for (const image of screenshotImages) {
                    const source = absolute(
                        image.getAttribute("data-lazy_src") || image.getAttribute("data-lazy-src") ||
                        image.getAttribute("data-src") || image.getAttribute("data-original") ||
                        image.currentSrc || image.getAttribute("srcset")?.split(/\\s+/)[0] ||
                        image.getAttribute("data-srcset")?.split(/\\s+/)[0] || image.getAttribute("src")
                    );
                    if (source) galleryCandidates.push(source);
                }
                const galleryURLs = galleryCandidates
                    .filter(value => {
                        try {
                            const parsed = new URL(value);
                            return parsed.hostname === "img.itch.zone"
                                || /\\.(png|jpe?g|webp|gif)$/i.test(parsed.pathname);
                        } catch (_) {
                            return false;
                        }
                    })
                    .filter((value, index, array) => array.indexOf(value) === index)
                    .slice(0, 30);
                const galleryResolved = galleryURLs.length > 0
                    || Boolean(galleryContainer && galleryContainer.querySelector("img, a[href]"));

                const tagsResolved = Boolean(document.querySelector(
                    '.game_tags, .game_page_tags, a.game_tag[href], .game_info_panel_widget a[href*="/games/tag-"]'
                ));
                const discoveryTags = Array.from(document.querySelectorAll(
                    'a.game_tag[href], .game_tags a[href], .game_info_panel_widget a[href*="/games/tag-"]'
                )).map(anchor => ({
                    name: clean(anchor),
                    url: absolute(anchor.getAttribute("href"))
                })).filter(tag => tag.name && tag.url && new URL(tag.url).pathname.includes("/games/tag-"))
                  .filter((tag, index, array) => array.findIndex(item => item.url === tag.url) === index)
                  .slice(0, 20);

                const engineTagText = Array.from(document.querySelectorAll('a[href]'))
                    .filter(anchor => {
                        const href = anchor.getAttribute("href") || "";
                        return href.includes("/games/tag-")
                            || href.includes("/games/made-with-")
                            || href.includes("/games/engine-");
                    })
                    .map(anchor => clean(anchor) + " " + (anchor.getAttribute("href") || ""))
                    .join(" ");
                const tagText = discoveryTags.map(tag => tag.name + " " + tag.url).join(" ")
                    + " " + engineTagText;
                const normalizedEngineText = tagText.toLowerCase().replace(/[^a-z0-9]+/g, "");
                const engineRules = [
                    { name: "Ren'Py", key: "renpy" },
                    { name: "Unity", key: "unity" },
                    { name: "Unreal Engine", key: "unrealengine" },
                    { name: "Godot", key: "godot" },
                    { name: "RPG Maker", key: "rpgmaker" },
                    { name: "TyranoBuilder", key: "tyranobuilder" },
                    { name: "Wolf RPG Editor", key: "wolfrpg" },
                    { name: "GameMaker", key: "gamemaker" },
                    { name: "Adventure Game Studio", key: "adventuregamestudio" },
                    { name: "Visual Novel Maker", key: "visualnovelmaker" }
                ];
                const engine = engineRules.find(rule => normalizedEngineText.includes(rule.key))?.name
                    || (parserProfile === "adultRenPy" ? "Ren'Py" : null);

                const authorLink = document.querySelector(".game_author a[href], .header_links .user_link[href], a.user_link[href]");
                const authorURL = authorLink ? absolute(authorLink.getAttribute("href")) : null;
                const authorAvatar = document.querySelector(
                    ".game_author img, .user_avatar img, .user_avatar, .user_avatar_image, .user_link img, .header_links img, img.avatar"
                );
                const authorAvatarRaw = authorAvatar
                    ? (authorAvatar.getAttribute("data-lazy_src") || authorAvatar.getAttribute("data-lazy-src")
                        || authorAvatar.getAttribute("data-src") || authorAvatar.currentSrc
                        || authorAvatar.getAttribute("src")
                        || (authorAvatar.getAttribute("style") || "").match(/url\\(['"]?([^)'"]+)/i)?.[1])
                    : null;
                const authorAvatarURL = absolute(authorAvatarRaw);

                const links = Array.from(document.querySelectorAll("a[href]")).map(a => absolute(a.getAttribute("href"))).filter(Boolean);
                const patreonURL = links.find(value => /(^|\\.)patreon\\.com$/i.test(new URL(value).hostname)) || null;
                const discordURL = links.find(value => {
                    try {
                        const parsed = new URL(value);
                        return parsed.hostname === "discord.gg"
                            || parsed.hostname === "discord.com" && parsed.pathname.startsWith("/invite/");
                    } catch (_) {
                        return false;
                    }
                }) || null;

                return JSON.stringify({
                    isCompleteSnapshot,
                    ageGateRequired,
                    description,
                    descriptionResolved,
                    developer,
                    coverURL,
                    galleryURLs,
                    galleryResolved,
                    authorURL,
                    authorAvatarURL,
                    patreonURL,
                    discordURL,
                    discoveryTags,
                    tagsResolved,
                    engine,
                    scriptError: null
                });
            } catch (error) {
                return JSON.stringify({
                    isCompleteSnapshot: false,
                    description: null,
                    descriptionResolved: false,
                    developer: null,
                    coverURL: null,
                    galleryURLs: [],
                    galleryResolved: false,
                    authorURL: null,
                    authorAvatarURL: null,
                    patreonURL: null,
                    discordURL: null,
                    discoveryTags: [],
                    tagsResolved: false,
                    engine: null,
                    scriptError: String(error)
                });
            }
        })();
        """

    static func source(for profile: GameDetailParserProfile) -> String {
        let replacements: [(String, String)] = [
            ("__PARSER_PROFILE__", profile.rawValue),
            ("__STANDARD_DESCRIPTION_SELECTORS__", Self.json(GameDetailParserProfile.standard.descriptionSelectors)),
            ("__STANDARD_GALLERY_CONTAINERS__", Self.json(GameDetailParserProfile.standard.galleryContainerSelectors)),
            ("__STANDARD_GALLERY_IMAGES__", Self.json(GameDetailParserProfile.standard.galleryImageSelectors)),
            ("__STANDARD_GALLERY_ANCHORS__", Self.json(GameDetailParserProfile.standard.galleryAnchorSelectors)),
            ("__RENPY_DESCRIPTION_SELECTORS__", Self.json(GameDetailParserProfile.adultRenPy.descriptionSelectors)),
            ("__RENPY_GALLERY_CONTAINERS__", Self.json(GameDetailParserProfile.adultRenPy.galleryContainerSelectors)),
            ("__RENPY_GALLERY_IMAGES__", Self.json(GameDetailParserProfile.adultRenPy.galleryImageSelectors)),
            ("__RENPY_GALLERY_ANCHORS__", Self.json(GameDetailParserProfile.adultRenPy.galleryAnchorSelectors)),
            ("__ADULT3D_DESCRIPTION_SELECTORS__", Self.json(GameDetailParserProfile.adult3D.descriptionSelectors)),
            ("__ADULT3D_GALLERY_CONTAINERS__", Self.json(GameDetailParserProfile.adult3D.galleryContainerSelectors)),
            ("__ADULT3D_GALLERY_IMAGES__", Self.json(GameDetailParserProfile.adult3D.galleryImageSelectors)),
            ("__ADULT3D_GALLERY_ANCHORS__", Self.json(GameDetailParserProfile.adult3D.galleryAnchorSelectors))
        ]
        return replacements.reduce(source) { result, replacement in
            result.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
    }

    private static func json(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let value = String(data: data, encoding: .utf8) else { return "[]" }
        return value
    }
}

/// Preloads missing/stale itch.io detail pages in a bounded sequential WebKit queue.
/// Cached detail data is rendered immediately; incomplete records are prioritized for recovery.
@MainActor
final class GameDetailPrefetchService: NSObject, WKNavigationDelegate {
    static let shared = GameDetailPrefetchService()

    private let database = AppDatabase.shared
    private lazy var gameRepository = GameRepository(database: database)
    private lazy var developerRepository = DeveloperRepository(database: database)
    private var isRunning = false
    private var webView: WKWebView?
    private var currentRecord: LibraryRecord?
    private var continuation: CheckedContinuation<Void, Never>?

    private override init() { super.init() }

    func prefetch(records: [LibraryRecord], library: PersonalLibraryStore, limit: Int = 24) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let sortedCandidates = records.compactMap { record -> (record: LibraryRecord, updatedAt: Date)? in
            guard let rawURL = record.gameURL, URL(string: rawURL) != nil else { return nil }
            let stored = try? gameRepository.game(id: record.id)
            let cachedDetail = try? GameDetailRepository.shared.detail(for: record.id)
            let isComplete = cachedDetail?.fetchStatus == .complete
            let hasCachedAvatar: Bool = {
                guard let developerID = stored?.developerID else {
                    return record.developerProfileURL == nil
                }
                guard let developer = try? developerRepository.developer(id: developerID) else { return false }
                return developer.avatarURL != nil
            }()
            let freshnessDate = cachedDetail?.fetchedAt
            let isFresh = freshnessDate.map { Date().timeIntervalSince($0) < 3 * 24 * 60 * 60 } ?? false
            guard !isComplete || !isFresh || !hasCachedAvatar else { return nil }
            return (record, freshnessDate ?? .distantPast)
        }.sorted { $0.updatedAt < $1.updatedAt }
        let candidates = Array(sortedCandidates.prefix(max(1, limit)))

        for candidate in candidates {
            if Task.isCancelled { break }
            guard let url = URL(string: candidate.record.gameURL ?? "") else { continue }
            await load(candidate.record, url: url)
            guard let stored = try? gameRepository.game(id: candidate.record.id) else { continue }

            let cachedDetail = try? GameDetailRepository.shared.detail(for: candidate.record.id)
            var imageURLs = [stored.coverURL].compactMap { $0 }.compactMap { URL(string: $0) }
            imageURLs += (cachedDetail?.galleryURLs ?? []).prefix(8).compactMap { URL(string: $0) }
            await PersistentImageCache.shared.prefetch(imageURLs)

            if let description = cachedDetail?.description, !description.isEmpty, TranslationService.isConfigured {
                _ = try? await TranslationService.translateCached(
                    description,
                    scope: "game-description:\(candidate.record.id)"
                )
            }
            for update in library.updates(for: candidate.record.id).prefix(5) {
                let source = [update.title, update.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                guard !source.isEmpty, TranslationService.isConfigured else { continue }
                _ = try? await TranslationService.translateCached(
                    source,
                    scope: "devlog:\(candidate.record.id):\(update.id)"
                )
            }
        }
    }

    private func load(_ record: LibraryRecord, url: URL) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            currentRecord = record
            let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            view.navigationDelegate = self
            webView = view
            var request = URLRequest(url: url)
            request.timeoutInterval = 35
            request.cachePolicy = .returnCacheDataElseLoad
            view.load(request)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let result = try await webView.evaluateJavaScript(GamePageScript.source)
                persist(result)
            } catch {
                finish()
            }
        }
    }

    private func persist(_ result: Any?) {
        guard let record = currentRecord,
              let json = result as? String,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GamePagePayload.self, from: data),
              payload.scriptError == nil,
              payload.isCompleteSnapshot == true else {
            finish()
            return
        }

        let authorURL = payload.authorURL ?? URL(string: record.developerProfileURL ?? "")
        let developerID = authorURL.map { DeveloperRepository.canonicalID(for: $0.absoluteString) }
        do {
            let existingDeveloper = try developerID.flatMap { try developerRepository.developer(id: $0) }
            let developerName = GameDetailRepository.resolvedDeveloperName(
                incoming: payload.developer,
                existing: existingDeveloper?.name,
                library: record.developer
            )
            let safeDeveloperID = GameDeveloperReferencePolicy.resolvedID(
                candidateID: developerID,
                hasUsableName: developerName != nil,
                existingDeveloperExists: existingDeveloper != nil
            )
            if let safeDeveloperID, let developerName {
                try developerRepository.upsertIdentity(
                    id: safeDeveloperID,
                    name: developerName,
                    profileURL: authorURL?.absoluteString,
                    patreonURL: payload.patreonURL?.absoluteString,
                    discordURL: payload.discordURL?.absoluteString
                )
            }
            try gameRepository.upsertMetadata(
                id: record.id,
                title: record.title,
                gameURL: record.gameURL,
                coverURL: payload.coverURL?.absoluteString ?? record.coverURL,
                engine: payload.engine,
                developerID: safeDeveloperID
            )
            try GameDetailRepository.shared.applyPageSnapshot(
                GameDetailPageSnapshot(
                    description: payload.description,
                    descriptionResolved: payload.descriptionResolved == true,
                    galleryURLs: (payload.galleryURLs ?? []).map(\.absoluteString),
                    galleryResolved: payload.galleryResolved == true,
                    discoveryTags: payload.discoveryTags ?? [],
                    tagsResolved: payload.tagsResolved == true
                ),
                for: record.id
            )
        } catch {
            print("itchPocket detail prefetch persistence failed: \(error)")
        }
        if let authorURL {
            Task {
                _ = await PatreonAvatarService.shared.avatarURL(
                    authorURL: authorURL,
                    gameURL: URL(string: record.gameURL ?? "")
                )
            }
        }
        finish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish()
    }

    private func finish() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        currentRecord = nil
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private struct DetailPageReader: UIViewRepresentable {
    let url: URL?
    let profile: GameDetailParserProfile
    let reloadToken: UUID
    let onLoad: (GameDetailPayload) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )

        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        context.coordinator.currentToken = reloadToken

        guard let url else {
            DispatchQueue.main.async {
                context.coordinator.parent.onError("游戏页面地址无效。")
            }
            return webView
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 40
        request.cachePolicy = .useProtocolCachePolicy
        context.coordinator.markNavigationStarted()
        webView.load(request)

        return webView
    }

    func updateUIView(
        _ webView: WKWebView,
        context: Context
    ) {
        context.coordinator.parent = self

        guard context.coordinator.currentToken != reloadToken else {
            return
        }

        context.coordinator.currentToken = reloadToken
        context.coordinator.finished = false

        guard let url else {
            onError("游戏页面地址无效。")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 40
        request.cachePolicy = .useProtocolCachePolicy
        context.coordinator.markNavigationStarted()
        webView.load(request)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DetailPageReader
        var currentToken: UUID?
        var finished = false
        private var navigationStartedAt: Date?

        init(parent: DetailPageReader) {
            self.parent = parent
        }

        func markNavigationStarted() {
            navigationStartedAt = Date()
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            finished = false
            let extractionStartedAt = Date()
            let navigationDuration = navigationStartedAt.map { extractionStartedAt.timeIntervalSince($0) } ?? 0

            webView.evaluateJavaScript(GamePageScript.source(for: self.parent.profile)) { result, error in
                guard !self.finished else { return }
                let scriptDuration = Date().timeIntervalSince(extractionStartedAt)

                if let error {
                    self.fail(
                        "读取游戏主页失败：\(error.localizedDescription)"
                    )
                    return
                }

                let decodingStartedAt = Date()
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(
                        GamePagePayload.self,
                        from: data
                      ) else {
                    self.fail("游戏主页返回的数据无法解析。请重新读取。")
                    return
                }
                let decodingDuration = Date().timeIntervalSince(decodingStartedAt)

                if let scriptError = payload.scriptError {
                    self.fail("游戏主页 JavaScript 错误：\(scriptError)")
                    return
                }

                if payload.ageGateRequired == true {
                    self.fail("itch.io 要求先完成 18+ 年龄确认。请打开下方的 itch.io 页面，在应用内确认年龄后返回，再点“重新读取”。")
                    return
                }

                guard payload.isCompleteSnapshot == true else {
                    self.fail("无法确认当前页面是完整的 itch.io 游戏页面，已保留原有详情资料。")
                    return
                }

                let filteringStartedAt = Date()
                let cleanedDescription = GameDescriptionContentPolicy.cleaned(payload.description)
                let filteringDuration = Date().timeIntervalSince(filteringStartedAt)
                print(String(
                    format: "itchPocket detail.performance navigation=%.3fs javascript=%.3fs decode=%.3fs filtering=%.3fs",
                    navigationDuration,
                    scriptDuration,
                    decodingDuration,
                    filteringDuration
                ))

                self.finished = true

                DispatchQueue.main.async {
                    self.parent.onLoad(
                        GameDetailPayload(
                            description: cleanedDescription,
                            descriptionResolved: payload.descriptionResolved == true && cleanedDescription != nil,
                            developer: payload.developer,
                            coverURL: payload.coverURL,
                            galleryURLs: payload.galleryURLs ?? [],
                            galleryResolved: payload.galleryResolved == true,
                            authorURL: payload.authorURL,
                            authorAvatarURL: payload.authorAvatarURL,
                            patreonURL: payload.patreonURL,
                            discordURL: payload.discordURL,
                            discoveryTags: payload.discoveryTags ?? [],
                            tagsResolved: payload.tagsResolved == true,
                            engine: payload.engine
                        )
                    )
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        private func report(_ error: Error) {
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }

            fail(
                "无法打开 itch.io 游戏页面：\(error.localizedDescription)"
            )
        }

        private func fail(_ message: String) {
            guard !finished else { return }
            finished = true

            DispatchQueue.main.async {
                self.parent.onError(message)
            }
        }


    }
}
