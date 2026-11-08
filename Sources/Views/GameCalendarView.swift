import SwiftUI

struct GameCalendarView: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    @EnvironmentObject private var calendarStore: GameCalendarStore
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var showingEditor = false
    @State private var editingEvent: GameCalendarEvent?
    @State private var translatedEventTitles: [String: String] = [:]
    @State private var translatedEventNotes: [String: String] = [:]

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

    private var monthDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let dayRange = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let offset = (weekday + 5) % 7
        return Array(repeating: nil, count: offset) + dayRange.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: interval.start)
        }
    }

    private var selectedEvents: [GameCalendarEvent] { calendarStore.events(on: selectedDate) }
    private var timelineEvents: [GameCalendarEvent] { calendarStore.events.sorted { $0.date > $1.date } }
    private var translationTaskKey: String {
        calendarStore.events.filter { $0.kind == .update }
            .map { "\($0.id)|\($0.title)|\($0.notes)" }
            .joined(separator: "||")
    }

    private func chineseDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func translateCalendarEvents() async {
        guard TranslationService.isConfigured else { return }
        for event in timelineEvents where event.kind == .update {
            let rawTitle = event.title.replacingOccurrences(of: "更新：", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawTitle.isEmpty {
                do {
                    let result = try await TranslationService.translateCached(
                        rawTitle,
                        scope: "calendar-event-title:\(event.id)"
                    )
                    translatedEventTitles[event.id] = result.text
                } catch { }
            }

            let rawNote = cleanTimelineNote(event.notes)
            if !rawNote.isEmpty {
                do {
                    let result = try await TranslationService.translateCached(
                        rawNote,
                        scope: "calendar-event-note:\(event.id)"
                    )
                    translatedEventNotes[event.id] = result.text
                } catch { }
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    calendarCard
                    selectedDaySection
                    timelineSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .task(id: translationTaskKey) {
                await translateCalendarEvents()
            }
            .navigationTitle("游戏日历")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { GameUpdateMonitorView() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel("游戏更新提醒")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedDate = calendar.startOfDay(for: Date())
                        month = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
                    } label: { Image(systemName: "dot.scope") }
                    .accessibilityLabel("回到今天")
                }
            }
            .sheet(isPresented: $showingEditor) {
                CalendarEventEditor(event: editingEvent, initialDate: selectedDate, games: library.records) { event in
                    if editingEvent == nil { calendarStore.add(event) } else { calendarStore.update(event) }
                }
            }
        }
    }

    private var calendarCard: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chineseDate(month, format: "yyyy年M月"))
                        .font(.title2.bold())
                }
                Spacer()
                HStack(spacing: 8) {
                    monthButton("chevron.left") {
                        month = calendar.date(byAdding: .month, value: -1, to: month) ?? month
                    }
                    monthButton("chevron.right") {
                        month = calendar.date(byAdding: .month, value: 1, to: month) ?? month
                    }
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                    Text(day)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 3)
                }
                ForEach(Array(monthDays.enumerated()), id: \.offset) { item in
                    if let day = item.element {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 58)
                    }
                }
            }

            HStack(spacing: 14) {
                legendItem(color: .blue, title: "计划游玩")
                legendItem(color: .purple, title: "预计发售")
                legendItem(color: .orange, title: "游戏更新")
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .appGlassSurface(cornerRadius: 22)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func monthButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(AppGlassButtonStyle())
    }

    private func legendItem(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private func eventColor(_ kind: GameCalendarEventKind) -> Color {
        switch kind {
        case .plannedPlay: return .blue
        case .release: return .purple
        case .update: return .orange
        case .custom: return .gray
        }
    }

    private func displayTitle(for event: GameCalendarEvent) -> String {
        event.kind == .update ? event.gameTitle : event.title
    }

    private func dayCell(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let dayEvents = calendarStore.events(on: date)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedDate = calendar.startOfDay(for: date)
            }
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.subheadline.weight(isSelected || isToday ? .bold : .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                VStack(spacing: 2) {
                    ForEach(dayEvents.prefix(2)) { event in
                        Text(displayTitle(for: event))
                            .font(.system(size: 7, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .white : eventColor(event.kind))
                            .padding(.horizontal, 3)
                            .frame(maxWidth: .infinity)
                    }
                    if dayEvents.count > 2 {
                        Text("+\(dayEvents.count - 2)")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    }
                }
                .frame(height: 22, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Color.accentColor : (isToday ? Color.accentColor.opacity(0.10) : .clear))
            }
            .overlay {
                if !isSelected && !dayEvents.isEmpty {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var selectedDaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("所选日期")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(chineseDate(selectedDate, format: "yyyy年M月d日 EEEE"))
                        .font(.headline)
                }
                Spacer()
                Button {
                    editingEvent = nil
                    showingEditor = true
                } label: {
                    Label("添加事件", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.11), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if selectedEvents.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 42, height: 42)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("这一天还没有安排").font(.subheadline.weight(.semibold))
                        Text("添加计划游玩、预计发售或其他事件")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appGlassSurface(cornerRadius: 17)
                .overlay {
                    RoundedRectangle(cornerRadius: 17)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
            } else {
                VStack(spacing: 9) {
                    ForEach(selectedEvents) { event in
                        selectedEventRow(event)
                    }
                }
            }
        }
    }

    private func selectedEventRow(_ event: GameCalendarEvent) -> some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor(event.kind))
                .frame(width: 4, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                if event.kind == .update {
                    Text(calendarUpdateTitle(event))
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(event.gameTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(event.title).font(.subheadline.weight(.semibold))
                }
                Text("\(event.kind.rawValue) · \(chineseDate(event.date, format: "HH:mm"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            eventMenu(event)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .appGlassSurface(cornerRadius: 15)
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("游戏动态")
                        .font(.title3.bold())
                    Text("按照更新与事件日期排列")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(timelineEvents.count) 条记录")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if timelineEvents.isEmpty {
                ContentUnavailableView("还没有游戏动态", systemImage: "clock", description: Text("游戏更新、历史 Devlog 和日历事件会显示在这里。"))
                    .padding(.top, 8)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(timelineEvents) { event in
                        timelineRow(event)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func timelineRow(_ event: GameCalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 2) {
                Text(chineseDate(event.date, format: "d日"))
                    .font(.title3.bold().monospacedDigit())
                Text(chineseDate(event.date, format: "M月"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 43)
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 7) {
                    Circle().fill(eventColor(event.kind)).frame(width: 7, height: 7)
                    Text(event.kind.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(eventColor(event.kind))
                    Spacer()
                    Text(chineseDate(event.date, format: "HH:mm"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Text(displayTitle(for: event))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if event.kind == .update {
                    Text(calendarUpdateTitle(event))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let note = translatedEventNotes[event.id] ?? cleanTimelineNote(event.notes)
                if !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack {
                    Spacer()
                    eventMenu(event)
                }
                .padding(.top, -4)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.065), lineWidth: 1)
            }
        }
    }

    private func calendarUpdateTitle(_ event: GameCalendarEvent) -> String {
        let rawTitle = event.title
            .replacingOccurrences(of: "更新：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return translatedEventTitles[event.id] ?? (rawTitle.isEmpty ? "游戏更新" : rawTitle)
    }

    private func cleanTimelineNote(_ note: String) -> String {
        note.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("https://") && !$0.hasPrefix("http://") && !$0.hasPrefix("来源：") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func eventMenu(_ event: GameCalendarEvent) -> some View {
        Menu {
            Button("编辑", systemImage: "pencil") {
                editingEvent = event
                showingEditor = true
            }
            Button("删除", systemImage: "trash", role: .destructive) {
                calendarStore.delete(event.id)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
    }
}

private struct CalendarEventEditor: View {
    @Environment(\.dismiss) private var dismiss
    let event: GameCalendarEvent?
    let initialDate: Date
    let games: [LibraryRecord]
    let onSave: (GameCalendarEvent) -> Void

    @State private var selectedGameID = ""
    @State private var title = ""
    @State private var date = Date()
    @State private var kind: GameCalendarEventKind = .plannedPlay
    @State private var reminderEnabled = true
    @State private var reminderMinutes = 60
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("关联游戏") {
                    if games.isEmpty {
                        Text("个人游戏库为空，暂时无法关联游戏。").foregroundStyle(.secondary)
                    } else {
                        Picker("游戏", selection: $selectedGameID) {
                            ForEach(games) { game in Text(game.title).tag(game.id) }
                        }
                    }
                }
                Section("事件") {
                    TextField("事件名称", text: $title)
                    Picker("类型", selection: $kind) {
                        ForEach(GameCalendarEventKind.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    DatePicker("日期和时间", selection: $date)
                    TextField("备注", text: $notes, axis: .vertical)
                }
                Section("提醒") {
                    Toggle("开启本地通知", isOn: $reminderEnabled)
                    if reminderEnabled {
                        Picker("提前提醒", selection: $reminderMinutes) {
                            Text("准时").tag(0)
                            Text("提前 15 分钟").tag(15)
                            Text("提前 1 小时").tag(60)
                            Text("提前 1 天").tag(1440)
                        }
                    }
                }
            }
            .navigationTitle(event == nil ? "添加日历事件" : "编辑事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let game = games.first(where: { $0.id == selectedGameID }) else { return }
                        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let value = GameCalendarEvent(
                            id: event?.id ?? UUID().uuidString,
                            gameID: game.id,
                            gameTitle: game.title,
                            gameURL: game.gameURL,
                            title: cleanTitle.isEmpty ? kind.rawValue : cleanTitle,
                            date: date,
                            kind: kind,
                            reminderEnabled: reminderEnabled,
                            reminderMinutes: reminderMinutes,
                            notes: notes
                        )
                        onSave(value)
                        dismiss()
                    }
                    .disabled(games.isEmpty)
                }
            }
            .onAppear {
                if let event {
                    selectedGameID = event.gameID
                    title = event.title
                    date = event.date
                    kind = event.kind
                    reminderEnabled = event.reminderEnabled
                    reminderMinutes = event.reminderMinutes
                    notes = event.notes
                } else {
                    selectedGameID = games.first?.id ?? ""
                    date = initialDate
                }
            }
        }
    }
}
