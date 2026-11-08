import SwiftUI
import WebKit

private enum ItchPublicCollection {
    static let url = URL(string: "https://itch.io/c/5891862/liano1125s-collection")!
}

struct PublicCollectionGame: Codable, Identifiable {
    let id: String
    let title: String
    let url: URL?
    let coverURL: URL?
    let description: String?
    let developer: String?
    let platforms: [String]
    var developerProfileURL: URL? = nil
}

struct LibraryView: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    @State private var sourceGames: [PublicCollectionGame]
    @State private var shouldLoadSource: Bool
    @State private var searchText = ""
    @State private var selectedStatus: LibraryStatus?
    @State private var showingSource = false
    @State private var editingRecord: LibraryRecord?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reloadToken = UUID()

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    init() {
        let cached = DiscoveryCacheStore.load([PublicCollectionGame].self, key: "public-collection:liano1125:v1") ?? []
        _sourceGames = State(initialValue: cached)
        _shouldLoadSource = State(initialValue: cached.isEmpty)
        _isLoading = State(initialValue: cached.isEmpty)
    }

    private var filteredRecords: [LibraryRecord] {
        library.records
            .filter { record in
                (selectedStatus == nil || record.status == selectedStatus)
                && (searchText.isEmpty
                    || record.title.localizedCaseInsensitiveContains(searchText)
                    || (record.developer ?? "").localizedCaseInsensitiveContains(searchText))
            }
            .sorted { lhs, rhs in
                let leftTime = lhs.sparkPlaytimeSeconds.flatMap { $0.isFinite ? $0 : nil }
                let rightTime = rhs.sparkPlaytimeSeconds.flatMap { $0.isFinite ? $0 : nil }
                switch (leftTime, rightTime) {
                case let (left?, right?):
                    if left != right { return left > right }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
    }
    private var filteredSourceGames: [PublicCollectionGame] {
        sourceGames.filter { game in
            searchText.isEmpty
            || game.title.localizedCaseInsensitiveContains(searchText)
            || (game.developer ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if shouldLoadSource {
                CollectionReader(
                    url: ItchPublicCollection.url,
                    reloadToken: reloadToken,
                    onLoad: { games in
                         sourceGames = games
                         DiscoveryCacheStore.save(games, key: "public-collection:liano1125:v1", timeToLive: 24 * 60 * 60)
                         shouldLoadSource = false
                         if showingSource {
                             importSourceGamesAsPlaying()
                         }
                         isLoading = false
                         errorMessage = nil
                     },
                    onError: { errorMessage = $0; isLoading = false; shouldLoadSource = false }
                )
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        statusPicker

                        if showingSource {
                            sourceSection
                        } else {
                            personalSection
                        }
                    }
                    .padding()
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("游戏库")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: showingSource ? "搜索合集游戏" : "搜索我的游戏")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSource.toggle()
                        if showingSource {
                            importSourceGamesAsPlaying()
                        }
                    } label: {
                        Image(systemName: showingSource ? "books.vertical" : "plus.circle")
                    }
                    .accessibilityLabel(showingSource ? "查看我的游戏" : "从公开合集添加游戏")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isLoading = true
                        shouldLoadSource = true
                        reloadToken = UUID()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("刷新公开合集")
                }
            }
            .sheet(item: $editingRecord) { record in
                LibraryNoteEditor(record: record) { library.update($0) }
            }
        }
    }

    private func importSourceGamesAsPlaying() {
        for game in sourceGames where !library.contains(game.id) {
            library.add(game, status: .playing)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(showingSource ? "发现并添加游戏" : "我的游戏")
                .font(.title2.bold())
        }
    }


    private var statusPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("游戏状态").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    statusChip(title: "全部", status: nil)
                    ForEach(LibraryStatus.allCases) { status in
                        statusChip(title: status.rawValue, status: status)
                    }
                }
            }
        }
    }

    private func statusChip(title: String, status: LibraryStatus?) -> some View {
        let selected = selectedStatus == status
        return Button {
            selectedStatus = status
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: Capsule())
                .appGlassSurface(cornerRadius: 50)
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .disabled(showingSource)
    }

    @ViewBuilder
    private var personalSection: some View {
        if filteredRecords.isEmpty {
            ContentUnavailableView {
                Label(searchText.isEmpty ? "你的游戏库还是空的" : "没有找到游戏", systemImage: "gamecontroller")
            } description: {
                Text(searchText.isEmpty
                     ? "从右上角的加号进入公开合集，把喜欢的游戏加入这里。"
                     : "试试其他游戏名称或开发者。")
            } actions: {
                if searchText.isEmpty {
                    Button("浏览公开合集") {
                        showingSource = true
                        importSourceGamesAsPlaying()
                    }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 26)
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(filteredRecords) { record in
                    PersonalGameCard(
                        record: record,
                        onEdit: { editingRecord = record },
                        onUpdate: { library.update($0) },
                        onRemove: { library.remove(record.id) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        if isLoading && sourceGames.isEmpty {
            ProgressView("正在读取 itch.io 公开合集…").frame(maxWidth: .infinity).padding(.top, 40)
        } else if let errorMessage, sourceGames.isEmpty {
            ContentUnavailableView("读取合集失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if filteredSourceGames.isEmpty {
            ContentUnavailableView("没有找到游戏", systemImage: "magnifyingglass")
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(filteredSourceGames) { game in
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink {
                            GameDetailView(game: game)
                                .safeAreaInset(edge: .bottom) {
                                    LibraryGameActions(game: game)
                                }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                GameCover(url: game.coverURL)
                                Text(game.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                                if let developer = game.developer {
                                    Text(developer).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Button {
                            library.add(game)
                        } label: {
                            Label(library.contains(game.id) ? "在玩" : "加入在玩", systemImage: library.contains(game.id) ? "gamecontroller" : "plus")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(library.contains(game.id))
                    }
                    .padding(10)
                    .appGlassSurface(cornerRadius: 17)
                }
            }
        }
    }
}

private struct PersonalGameCard: View {
    let record: LibraryRecord
    let onEdit: () -> Void
    let onUpdate: (LibraryRecord) -> Void
    let onRemove: () -> Void

    private var detailGame: PublicCollectionGame {
        PublicCollectionGame(
            id: record.id,
            title: record.title,
            url: URL(string: record.gameURL ?? ""),
            coverURL: URL(string: record.coverURL ?? ""),
            description: nil,
            developer: record.developer,
            platforms: [],
            developerProfileURL: URL(string: record.developerProfileURL ?? "")
        )
    }

    private var latestUpdateText: String? {
        guard let update = record.gameUpdates?.max(by: {
            ($0.publishedAt ?? $0.detectedAt) < ($1.publishedAt ?? $1.detectedAt)
        }) else { return nil }
        return "最近更新 · \((update.publishedAt ?? update.detectedAt).formatted(date: .abbreviated, time: .omitted))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            NavigationLink {
                GameDetailView(game: detailGame)
                    .safeAreaInset(edge: .bottom) {
                        LibraryGameActions(game: detailGame)
                    }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    GameCover(url: URL(string: record.coverURL ?? ""))
                    Text(record.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                        .frame(height: 34, alignment: .topLeading)
                    Text(record.developer?.isEmpty == false ? record.developer! : " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: 13, alignment: .leading)
                    Text(latestUpdateText ?? " ")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .frame(height: 14, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(LibraryStatus.allCases) { status in
                    Button {
                        var copy = record
                        copy.status = status
                        onUpdate(copy)
                    } label: {
                        Label(status.rawValue, systemImage: status.symbol)
                    }
                }
                Button {
                    var copy = record
                    copy.isFavorite.toggle()
                    onUpdate(copy)
                } label: {
                    Label(record.isFavorite ? "取消收藏" : "收藏", systemImage: "heart")
                }
                Button(action: onEdit) {
                    Label("编辑备注", systemImage: "note.text")
                }
                Button(role: .destructive, action: onRemove) {
                    Label("从游戏库移除", systemImage: "trash")
                }
            } label: {
                HStack(spacing: 6) {
                    Label(record.status.rawValue, systemImage: record.status.symbol)
                    Spacer(minLength: 4)
                    if record.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .appGlassSurface(cornerRadius: 50)
            }
            .buttonStyle(.plain)

            Text(record.notes.isEmpty ? " " : record.notes)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(height: 24, alignment: .topLeading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .appGlassSurface(cornerRadius: 16)
    }
}

private struct GameCover: View {
    let url: URL?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                CachedRemoteImage(url: url, contentMode: .fill) {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        // Every grid cell gets the same width, so this fixed ratio produces
        // identical cover bounds regardless of the source image's dimensions.
        .aspectRatio(1.25, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct LibraryNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var record: LibraryRecord
    let onSave: (LibraryRecord) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("游戏备注") {
                    TextEditor(text: $record.notes).frame(minHeight: 150)
                }
                Section {
                    Picker("游戏状态", selection: $record.status) {
                        ForEach(LibraryStatus.allCases) { status in
                            Text(status.rawValue).tag(status)
                        }
                    }
                    Toggle("加入收藏", isOn: $record.isFavorite)
                }
            }
            .navigationTitle(record.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(record); dismiss() }
                }
            }
        }
    }
}

private struct CollectionReader: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID
    let onLoad: ([PublicCollectionGame]) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        context.coordinator.token = reloadToken
        webView.load(URLRequest(url: url, timeoutInterval: 30))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.token != reloadToken else { return }
        context.coordinator.token = reloadToken
        webView.load(URLRequest(url: url, timeoutInterval: 30))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: CollectionReader
        var token: UUID?
        init(parent: CollectionReader) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(Self.script) { result, error in
                if let error {
                    DispatchQueue.main.async { self.parent.onError(error.localizedDescription) }
                    return
                }
                guard let json = result as? String, let data = json.data(using: .utf8) else {
                    DispatchQueue.main.async { self.parent.onError("公开合集没有返回可解析的数据。") }
                    return
                }
                do {
                    let games = try JSONDecoder().decode([PublicCollectionGame].self, from: data)
                    DispatchQueue.main.async { self.parent.onLoad(games) }
                } catch {
                    DispatchQueue.main.async { self.parent.onError("游戏数据解析失败：\(error.localizedDescription)") }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.onError(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.onError(error.localizedDescription) }
        }

        private static let script = """
        (() => {
          const clean = el => (el?.innerText || el?.textContent || "").replace(/\\s+/g, " ").trim();
          const abs = value => { try { return value ? new URL(value, location.href).href : null; } catch (_) { return null; } };
          const seen = new Set();
          return JSON.stringify(Array.from(document.querySelectorAll(".game_cell")).map(cell => {
            const link = cell.querySelector("a.game_link, .game_title a, a.title, a[href*='itch.io']");
            const href = link ? abs(link.getAttribute("href")) : null;
            const title = clean(cell.querySelector(".game_title, .title")) || clean(link);
            if (!title) return null;
            const id = cell.getAttribute("data-game_id") || href || title;
            if (seen.has(id)) return null;
            seen.add(id);
            const img = cell.querySelector(".game_thumb img, img");
            return {
              id: String(id), title, url: href,
              coverURL: abs(img?.getAttribute("data-lazy_src") || img?.getAttribute("data-lazy-src") || img?.getAttribute("data-src") || img?.currentSrc || img?.getAttribute("src")),
              description: clean(cell.querySelector(".game_text, .game_description, .game_blurb")) || null,
              developer: clean(cell.querySelector(".game_author a, .game_author, .author")) || null,
              developerProfileURL: abs(cell.querySelector(".game_author a[href], .author a[href]")?.getAttribute("href")),
              platforms: Array.from(cell.querySelectorAll(".game_platform, .game_platforms, .web_flag")).map(clean).filter(Boolean)
            };
          }).filter(Boolean));
        })();
        """
    }
}


// MARK: - Game Detail Library Actions

private struct LibraryGameActions: View {
    let game: PublicCollectionGame

    @EnvironmentObject private var library: PersonalLibraryStore
    @State private var showingNotesEditor = false
    @State private var notesDraft = ""

    private var record: LibraryRecord? {
        library.record(for: game.id)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let record {
                HStack(spacing: 12) {
                    Menu {
                        ForEach(LibraryStatus.allCases) { status in
                            Button {
                                guard var updated = library.record(for: game.id) else { return }
                                updated.status = status
                                library.update(updated)
                            } label: {
                                Label(status.rawValue, systemImage: status.symbol)
                            }
                        }
                    } label: {
                        Label(record.status.rawValue, systemImage: record.status.symbol)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .appGlassSurface(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)

                    Button {
                        guard var updated = library.record(for: game.id) else { return }
                        updated.isFavorite.toggle()
                        library.update(updated)
                    } label: {
                        Image(systemName: record.isFavorite ? "heart.fill" : "heart")
                            .font(.headline)
                            .foregroundStyle(record.isFavorite ? .pink : .primary)
                            .frame(width: 44, height: 42)
                            .appGlassSurface(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(record.isFavorite ? "取消收藏" : "收藏游戏")

                    Menu {
                        ForEach(library.collections) { collection in
                            Button {
                                library.toggleGame(game.id, in: collection.id)
                            } label: {
                                Label(collection.title, systemImage: library.containsGame(game.id, in: collection.id) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 42)
                            .appGlassSurface(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("管理所属合集")

                    Button {
                        notesDraft = record.notes
                        showingNotesEditor = true
                    } label: {
                        Image(systemName: "note.text")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 42)
                            .appGlassSurface(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑游戏备注")
                }

                if !record.notes.isEmpty {
                    Text(record.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Button {
                    library.add(game)
                } label: {
                    Label("加入在玩", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .appGlassSurface(cornerRadius: 18)
        .sheet(isPresented: $showingNotesEditor) {
            NavigationStack {
                Form {
                    Section("游戏备注") {
                        TextEditor(text: $notesDraft)
                            .frame(minHeight: 150)
                    }
                }
                .navigationTitle("编辑备注")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingNotesEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            if var updated = library.record(for: game.id) {
                                updated.notes = notesDraft
                                library.update(updated)
                            }
                            showingNotesEditor = false
                        }
                    }
                }
            }
        }
    }
}


private struct CollectionNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    private let existingTitle: String?
    let onSave: (String) -> Void

    init(collection: PersonalGameCollection?, onSave: @escaping (String) -> Void) {
        existingTitle = collection?.title
        _title = State(initialValue: collection?.title ?? "")
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("合集名称") {
                    TextField("例如：独立游戏精选", text: $title)
                        .textInputAutocapitalization(.sentences)
                }
            }
            .navigationTitle(existingTitle == nil ? "新建合集" : "编辑合集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(title.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
