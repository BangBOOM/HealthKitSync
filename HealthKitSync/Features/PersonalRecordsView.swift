import SwiftUI

struct PersonalRecordsView: View {
    @Environment(RecordStore.self) private var records
    @Environment(AssistantStore.self) private var assistant
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isInputFocused: Bool
    @State private var date = Date()
    @State private var editor: RecordEditorRequest?
    @State private var showingAssistant = false
    @State private var autoSend = false

    private var dateKey: String { RecordDate.key(date) }
    private var rows: [RecordRow] { records.rows.filter { $0.performedOn == dateKey } }

    var body: some View {
        @Bindable var assistant = assistant
        List {
            Section {
                DatePicker("记录日期", selection: $date, displayedComponents: .date)
                    .environment(\.calendar, RecordDate.calendar)
                    .environment(\.timeZone, RecordDate.calendar.timeZone)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                    ForEach(RecordKind.allCases) { kind in
                        Button {
                            isInputFocused = false
                            editor = RecordEditorRequest(kind: kind, date: dateKey)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Label { Text(kind.title) } icon: { RecordKindIcon(kind: kind) }.font(.subheadline)
                                    .lineLimit(1).minimumScaleFactor(0.85)
                                Text(rows.filter { $0.kind == kind }.reduce(0) { $0 + $1.amount }.formatted(.number.precision(.fractionLength(0...2))))
                                    .font(.system(.largeTitle, design: .rounded).bold())
                                    .lineLimit(1).minimumScaleFactor(0.5)
                                HStack { Text(kind.unitLabel); Spacer(); Image(systemName: "plus.circle.fill") }
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(14).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                }.listRowInsets(.init(top: 12, leading: 16, bottom: 12, trailing: 16))
            } footer: {
                if rows.contains(where: { $0.status != "已同步" }) { Text("合计包含本机待同步记录；上传结果待核对时保留上次缓存。") }
            }

            Section("当日明细") {
                if rows.isEmpty {
                    ContentUnavailableView("还没有记录", systemImage: "square.and.pencil", description: Text("点上方卡片填写，或在下方输入一句话。"))
                }
                ForEach(rows) { row in
                    Button {
                        isInputFocused = false
                        editor = RecordEditorRequest(kind: row.kind, date: row.performedOn, row: row)
                    } label: {
                        HStack(spacing: 12) {
                            RecordKindIcon(kind: row.kind).frame(width: 30).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.kind.title).foregroundStyle(.primary)
                                Text(row.status).font(.caption).foregroundStyle(row.status == "已同步" ? Color.secondary : Color.orange)
                                if let error = row.error { Text(error).font(.caption2).foregroundStyle(.red) }
                            }
                            Spacer()
                            Text("\(row.amount.formatted(.number.precision(.fractionLength(0...2)))) \(row.kind.unitLabel)").font(.headline).foregroundStyle(.primary)
                            if row.canEdit { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        }
                    }.disabled(!row.canEdit)
                }
            }
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
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("记录")
        .toolbar { Button("对话历史", systemImage: "bubble.left.and.bubble.right") { isInputFocused = false; autoSend = false; showingAssistant = true } }
        .refreshable { await records.sync() }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("记一句，或问问最近的记录…", text: $assistant.draft, axis: .vertical)
                    .focused($isInputFocused)
                    .lineLimit(1...4).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                if isInputFocused {
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { isInputFocused = false }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                Button { isInputFocused = false; autoSend = true; showingAssistant = true } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).frame(minWidth: 44, minHeight: 44) }
                    .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.isBusy)
                    .accessibilityLabel("发送给助手")
            }.padding().background(.regularMaterial)
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
