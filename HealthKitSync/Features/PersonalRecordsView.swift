import SwiftUI

struct PersonalRecordsView: View {
    @Environment(RecordStore.self) private var records
    @Environment(AssistantStore.self) private var assistant
    let showDate: (String) -> Void
    let openSettings: () -> Void
    @FocusState private var isInputFocused: Bool
    @State private var followsBottom = true
    @State private var bottomPosition: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        @Bindable var assistant = assistant
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                todayHeader(now: timeline.date)
            }
            RecordSyncStatus()
            if !assistant.modelConfigured || records.endpointID.isEmpty {
                Button("配置助手与数据服务", action: openSettings).font(.subheadline).padding(.vertical, 8)
            }
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if assistant.items.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("记下今天的一点进步").font(.title3.weight(.medium))
                                    Text("例如：做了 20 个俯卧撑，平板一分钟半。")
                                    Text("对话每天清空，运动记录保留。").font(.caption)
                                }.foregroundStyle(.secondary).padding(.vertical, 32)
                            }
                            ForEach(assistant.items) { item in
                                if item.role == "tool" {
                                    RecordResultCard(item: item, showDate: showDate)
                                } else if !item.text.isEmpty {
                                    Text(item.text).textSelection(.enabled)
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(item.role == "user" ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
                                        .accessibilityLabel((item.role == "user" ? "你：" : "助手：") + item.text)
                                }
                            }
                            if assistant.isBusy { ProgressView("正在处理…") }
                            if let error = assistant.error { Text(error).font(.caption).foregroundStyle(.red) }
                            Color.clear.frame(height: 1).id("bottom")
                                .background(GeometryReader { bottom in
                                    Color.clear.preference(key: ChatBottomKey.self, value: bottom.frame(in: .named("chatScroll")).maxY)
                                })
                        }.padding(.horizontal, 20).padding(.vertical, 12)
                    }
                    .coordinateSpace(name: "chatScroll")
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable { await records.sync() }
                    .onPreferenceChange(ChatBottomKey.self) { bottom in
                        bottomPosition = bottom
                        if isDragging { followsBottom = bottom <= geometry.size.height + 80 }
                    }
                    .simultaneousGesture(DragGesture().onChanged { _ in
                        isDragging = true
                        followsBottom = bottomPosition <= geometry.size.height + 80
                    }.onEnded { _ in isDragging = false })
                    .onChange(of: assistant.items.reduce(0) { $0 + $1.text.count }) { _, _ in
                        if followsBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: assistant.items.count) { _, _ in
                        if followsBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: geometry.size.height) { _, _ in
                        if followsBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("记录").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .task(id: records.endpointID) { await assistant.loadConversation(records: records) }
        .onChange(of: assistant.draft) { _, _ in assistant.saveDraft() }
        .onDisappear { isInputFocused = false }
    }

    private func todayHeader(now: Date) -> some View {
        let today = RecordDate.key(now)
        return HStack(spacing: 28) {
            ForEach(RecordKind.allCases) { kind in
                let amount = (try? RecordStatistics.series(rows: records.rows, from: today, to: today, activity: kind).total) ?? 0
                HStack(spacing: 8) {
                    RecordKindIcon(kind: kind).foregroundStyle(Color.accentColor)
                    Text(RecordStatistics.amount(amount, kind: kind, compact: true)).font(.title3.monospacedDigit().weight(.semibold))
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("今天\(kind.title)，\(RecordStatistics.amount(amount, kind: kind))")
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var composer: some View {
        @Bindable var assistant = assistant
        return VStack(alignment: .leading, spacing: 0) {
            if let row = assistant.selectedRecord {
                HStack {
                    Text("\(row.performedOn) · \(row.kind.title) \(RecordStatistics.amount(row.amount, kind: row.kind))").font(.caption).lineLimit(2)
                    Spacer()
                    Button("移除引用", systemImage: "xmark.circle.fill") { Task { await assistant.selectRecord(nil, records: records) } }
                        .labelStyle(.iconOnly).disabled(assistant.isBusy)
                }.padding(.horizontal, 24).padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ResetAssistantButton()
                TextField("记一句，或问问最近的记录…", text: $assistant.draft, axis: .vertical)
                    .focused($isInputFocused).lineLimit(1...5).padding(.vertical, 11)
                if isInputFocused {
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { isInputFocused = false }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary).frame(width: 44, height: 44)
                }
                if assistant.isBusy {
                    Button("停止", systemImage: "stop.circle.fill") { assistant.suspend() }
                        .labelStyle(.iconOnly).font(.system(size: 34)).frame(width: 44, height: 44)
                } else {
                    Button("发送", systemImage: "arrow.up.circle.fill") {
                        isInputFocused = false
                        followsBottom = true
                        Task { await assistant.send(records: records) }
                    }.labelStyle(.iconOnly).font(.system(size: 34)).frame(width: 44, height: 44)
                        .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.modifier(RecordComposerSurface())
        }
    }
}

private struct ChatBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct RecordSyncStatus: View {
    var horizontalPadding: CGFloat = 24
    @Environment(RecordStore.self) private var records
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .leading, spacing: 4) {
                if records.isSyncing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(records.syncStatus).font(.caption)
                        Spacer()
                        if records.canCancelSync { Button("停止") { records.cancelSync() }.font(.caption) }
                    }
                } else if let error = records.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("重试同步") { Task { await records.sync() } }.font(.caption)
                } else if records.rows.contains(where: { $0.status != "已同步" }) {
                    Text("包含待同步或待核对记录").font(.caption).foregroundStyle(.orange)
                }
                if let updated = records.snapshot.refreshedAt, records.error != nil || timeline.date.timeIntervalSince(updated) > 900 {
                    Text("缓存更新于 \(updated.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                } else if records.snapshot.refreshedAt == nil && !records.endpointID.isEmpty && !records.isSyncing {
                    Text("尚未同步，当前仅显示本机记录").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, horizontalPadding)
        }
    }
}
