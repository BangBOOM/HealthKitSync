import SwiftUI

struct PersonalRecordsView: View {
    @Environment(RecordStore.self) private var records
    @Environment(AssistantStore.self) private var assistant
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isInputFocused: Bool
    @State private var date = Date()
    @State private var deletingID: String?
    @State private var deletionError: String?
    @State private var editor: RecordEditorRequest?
    @State private var showingAssistant = false
    @State private var autoSend = false

    private var dateKey: String { RecordDate.key(date) }
    private var visibleRows: [RecordRow] { rows.filter { $0.id != deletingID } }
    private var rows: [RecordRow] { records.rows.filter { $0.performedOn == dateKey } }

    private func delete(_ row: RecordRow) {
        guard deletingID == nil else { return }
        isInputFocused = false
        deletingID = row.id
        Task {
            defer { deletingID = nil }
            do { try await records.delete(id: row.id) }
            catch { deletionError = error.localizedDescription }
        }
    }

    private func total(for kind: RecordKind) -> String {
        let amount = rows.filter { $0.kind == kind }.reduce(0.0) { $0 + $1.amount }
        return amount.formatted(.number.precision(.fractionLength(0...2)))
    }

    private var summaryCard: some View {
        VStack(spacing: 12) {
            DatePicker("记录日期", selection: $date, displayedComponents: .date)
                .environment(\.calendar, RecordDate.calendar)
                .environment(\.timeZone, RecordDate.calendar.timeZone)
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                ForEach(RecordKind.allCases) { kind in
                    Button {
                        isInputFocused = false
                        editor = RecordEditorRequest(kind: kind, date: dateKey)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Label { Text(kind.title) } icon: { RecordKindIcon(kind: kind) }.font(.subheadline)
                                .lineLimit(1).minimumScaleFactor(0.85)
                            Text(total(for: kind))
                                .font(.system(.largeTitle, design: .rounded).bold())
                                .lineLimit(1).minimumScaleFactor(0.5)
                            HStack { Text(kind.unitLabel); Spacer(); Image(systemName: "plus.circle.fill") }
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(14).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 20)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    var body: some View {
        @Bindable var assistant = assistant
        List {
            Section {
                summaryCard
            } footer: {
                if rows.contains(where: { $0.status != "已同步" }) { Text("合计包含本机待同步记录；上传结果待核对时保留上次缓存。") }
            }

            Section("当日明细") {
                if visibleRows.isEmpty {
                    ContentUnavailableView("还没有记录", systemImage: "square.and.pencil", description: Text("点上方卡片填写，或在下方输入一句话。"))
                }
                ForEach(visibleRows) { row in
                    Button {
                        isInputFocused = false
                        editor = RecordEditorRequest(kind: row.kind, date: row.performedOn, row: row)
                    } label: {
                        HStack(spacing: 12) {
                            RecordKindIcon(kind: row.kind).frame(width: 30).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.kind.title).foregroundStyle(.primary)
                                Text(deletingID == row.id ? "正在删除…" : row.status)
                                    .font(.caption).foregroundStyle(row.status == "已同步" ? Color.secondary : Color.orange)
                                if let error = row.error { Text(error).font(.caption2).foregroundStyle(.red) }
                            }
                            Spacer()
                            Text("\(row.amount.formatted(.number.precision(.fractionLength(0...2)))) \(row.kind.unitLabel)").font(.headline).foregroundStyle(.primary)
                            ZStack {
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    .opacity(deletingID == row.id ? 0 : 1)
                                if deletingID == row.id { ProgressView().controlSize(.small) }
                            }.frame(width: 16)
                        }
                    }.disabled(!row.canEdit || deletingID != nil)
                    .modifier(SwipeAwayRecord(enabled: row.canEdit && deletingID == nil) {
                        delete(row)
                    })
                }
            }
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            .listRowSeparator(.visible)
            Section {
                if let error = records.error { Label(error, systemImage: "exclamationmark.icloud").font(.caption).foregroundStyle(.orange) }
                if let refreshed = records.snapshot.refreshedAt {
                    Text("缓存更新于 \(refreshed.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await records.sync() } } label: {
                    HStack { Text("同步记录"); Spacer(); if records.isSyncing { ProgressView() } }
                }.disabled(records.isSyncing || records.endpointID.isEmpty)
                if records.endpointID.isEmpty { Text("请在设置中连接 heatmap 数据服务。").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .listStyle(.grouped)
        // Animate the optimistic removal and restore the row if deletion fails.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: visibleRows.map(\.id))
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("记录")
        .alert("删除未完成", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("好", role: .cancel) { deletionError = nil }
        } message: { Text(deletionError ?? "") }
        .toolbar { Button("对话历史", systemImage: "bubble.left.and.bubble.right") { isInputFocused = false; autoSend = false; showingAssistant = true } }
        .refreshable { await records.sync() }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 4) {
                TextField("记一句，或问问最近的记录…", text: $assistant.draft, axis: .vertical)
                    .focused($isInputFocused)
                    .lineLimit(1...4)
                    .padding(.leading, 12).padding(.vertical, 11)
                if isInputFocused {
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { isInputFocused = false }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44)
                }
                Button { isInputFocused = false; autoSend = true; showingAssistant = true } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).frame(minWidth: 44, minHeight: 44) }
                    .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.isBusy)
                    .accessibilityLabel("发送给助手")
            }.modifier(RecordComposerSurface())
        }
        .sheet(item: $editor) { request in RecordEditor(request: request) }
        .sheet(isPresented: $showingAssistant) {
            AssistantPanel(autoSend: autoSend, showDate: { day in date = RecordDate.date(day) ?? date })
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .onChange(of: assistant.draft) { _, _ in assistant.saveDraft() }
        .onDisappear { isInputFocused = false }
    }
}

private struct RecordEditorRequest: Identifiable {
    let id = UUID().uuidString
    let kind: RecordKind
    let date: String
    var row: RecordRow?
}

private struct RecordEditor: View {
    @Environment(RecordStore.self) private var records
    @Environment(\.dismiss) private var dismiss
    let request: RecordEditorRequest
    @State private var amount = ""
    @State private var date = Date()
    @State private var saving = false
    @State private var error: String?
    @FocusState private var isAmountFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(request.kind.unitLabel, text: $amount).keyboardType(request.kind == .pushups ? .numberPad : .decimalPad)
                        .focused($isAmountFocused)
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                        .environment(\.calendar, RecordDate.calendar).environment(\.timeZone, RecordDate.calendar.timeZone)
                } header: { Text(request.kind.title) } footer: { Text(request.row == nil ? "新增这一次的数量，同一天可以记录多次。" : "修改这一条记录，不改变当天其他记录。") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(request.row == nil ? "新增记录" : "修改记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "保存中…" : "保存") { Task { await save() } }.disabled(saving) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { isAmountFocused = false }
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear {
                date = RecordDate.date(request.date) ?? Date()
                if let row = request.row { amount = String(row.amount) }
            }
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")) else { throw RecordError.message("请输入有效数值") }
            if let row = request.row {
                _ = try await records.update(id: row.id, amount: value, performedOn: RecordDate.key(date), sourceID: request.id)
            } else {
                _ = try records.add([RecordIntent(activity: request.kind, amount: value, performedOn: RecordDate.key(date))], rawText: "\(request.kind.title) \(value) \(request.kind.unitLabel)", sourceID: request.id)
            }
            dismiss()
            Task { await records.sync() }
        } catch { self.error = error.localizedDescription }
    }
}
