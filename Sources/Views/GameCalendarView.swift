import SwiftUI

struct GameCalendarView: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    @EnvironmentObject private var calendarStore: GameCalendarStore
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var showingEditor = false
    @State private var editingEvent: GameCalendarEvent?

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

    private var monthDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let dayRange = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let offset = (weekday + 5) % 7
        return Array(repeating: nil, count: offset) + dayRange.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: interval.start) }
    }

    private var selectedEvents: [GameCalendarEvent] { calendarStore.events(on: selectedDate) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    monthHeader
                    weekdayHeader
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                            if let day {
                                dayCell(day)
                            } else {
                                Color.clear.frame(height: 42)
                            }
                        }
                    }
                    HStack {
                        Text(selectedDate.formatted(date: .complete, time: .omitted))
                            .font(.headline)
                        Spacer()
                        Button { editingEvent = nil; showingEditor = true } label: {
                            Label("添加事件", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    if selectedEvents.isEmpty {
                        ContentUnavailableView("这一天还没有安排", systemImage: "calendar", description: Text("可以添加计划游玩、预计发售或更新日期。"))
                            .padding(.top, 12)
                    } else {
                        ForEach(selectedEvents) { event in
                            eventRow(event)
                        }
                    }
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("游戏日历")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { selectedDate = calendar.startOfDay(for: Date()); month = calendar.dateInterval(of: .month, for: Date())?.start ?? Date() } label: {
                        Image(systemName: "dot.scope")
                    }
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

    private var monthHeader: some View {
        HStack {
            Button { month = calendar.date(byAdding: .month, value: -1, to: month) ?? month } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(month.formatted(.dateTime.year().month(.wide)))
                .font(.title2.bold())
            Spacer()
            Button { month = calendar.date(byAdding: .month, value: 1, to: month) ?? month } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.plain)
    }

    private var weekdayHeader: some View {
        let symbols = ["一", "二", "三", "四", "五", "六", "日"]
        return LazyVGrid(columns: columns) {
            ForEach(symbols, id: \.self) { Text(symbolsLabel($0)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
        }
    }

    private func symbolsLabel(_ value: String) -> String { value }

    private func dayCell(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let hasEvents = !calendarStore.events(on: date).isEmpty
        return Button { selectedDate = calendar.startOfDay(for: date) } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.subheadline.weight(isSelected || isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
                Circle().fill(hasEvents ? (isSelected ? .white : Color.accentColor) : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(isSelected ? Color.accentColor : (isToday ? Color.accentColor.opacity(0.12) : .clear), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    private func eventRow(_ event: GameCalendarEvent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: event.kind.symbol)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.subheadline.weight(.semibold))
                Text(event.gameTitle).font(.caption).foregroundStyle(.secondary)
                Text(event.date.formatted(date: .omitted, time: .shortened) + (event.reminderEnabled ? " · 已设提醒" : ""))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Button("编辑", systemImage: "pencil") { editingEvent = event; showingEditor = true }
                Button("删除", systemImage: "trash", role: .destructive) { calendarStore.delete(event.id) }
            } label: { Image(systemName: "ellipsis").padding(8) }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
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
                        let value = GameCalendarEvent(id: event?.id ?? UUID().uuidString, gameID: game.id, gameTitle: game.title, gameURL: game.gameURL, title: cleanTitle.isEmpty ? kind.rawValue : cleanTitle, date: date, kind: kind, reminderEnabled: reminderEnabled, reminderMinutes: reminderMinutes, notes: notes)
                        onSave(value)
                        dismiss()
                    }
                    .disabled(games.isEmpty)
                }
            }
            .onAppear {
                if let event {
                    selectedGameID = event.gameID; title = event.title; date = event.date; kind = event.kind
                    reminderEnabled = event.reminderEnabled; reminderMinutes = event.reminderMinutes; notes = event.notes
                } else {
                    selectedGameID = games.first?.id ?? ""; date = initialDate
                }
            }
        }
    }
}
