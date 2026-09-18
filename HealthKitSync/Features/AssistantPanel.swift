import SwiftUI
import WebKit

struct AssistantPanel: View {
    @Environment(RecordStore.self) private var records
    @Environment(AssistantStore.self) private var assistant
    @Environment(\.dismiss) private var dismiss
    let autoSend: Bool
    let showDate: (String) -> Void
    @State private var started = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        @Bindable var assistant = assistant
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if assistant.items.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("试试：今天做了 20 个俯卧撑，平板一分钟半。")
                                    Text("对话每天按北京时间清空，运动记录和未发送草稿保留。").font(.caption)
                                }.foregroundStyle(.secondary).padding(.vertical)
                            }
                            ForEach(assistant.items) { item in
                                if item.role == "tool" {
                                    ToolResultCard(item: item) { date in showDate(date); dismiss() }
                                } else if !item.text.isEmpty {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.role == "user" ? "你" : "助手").font(.caption).foregroundStyle(.secondary)
                                        Text(item.text).textSelection(.enabled)
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(item.role == "user" ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                                }
                            }
                            if assistant.isBusy { ProgressView("正在处理…") }
                            if let error = assistant.error { Text(error).font(.caption).foregroundStyle(.red) }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: assistant.items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                HStack(alignment: .bottom, spacing: 4) {
                    TextField("输入记录、纠正或查询", text: $assistant.draft, axis: .vertical).lineLimit(1...5)
                        .focused($isInputFocused)
                        .padding(.leading, 12).padding(.vertical, 11)
                    if isInputFocused {
                        Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { isInputFocused = false }
                            .labelStyle(.iconOnly).foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44)
                    }
                    if assistant.isBusy {
                        Button("停止", systemImage: "stop.circle.fill") { assistant.suspend() }.labelStyle(.iconOnly).font(.system(size: 34)).frame(minWidth: 44, minHeight: 44)
                    } else {
                        Button("发送", systemImage: "arrow.up.circle.fill") { isInputFocused = false; Task { await assistant.send(records: records) } }
                            .labelStyle(.iconOnly).font(.system(size: 34)).frame(minWidth: 44, minHeight: 44).disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.modifier(RecordComposerSurface())
                if let bridge = assistant.bridge {
                    AgentWebView(webView: bridge.webView).id(ObjectIdentifier(bridge)).frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true)
                }
            }
            .navigationTitle("记录助手").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task {
            guard !started else { return }
            started = true
            await assistant.open(records: records)
            if autoSend { await assistant.send(records: records) }
        }
        .onDisappear { isInputFocused = false; assistant.suspend() }
        .onChange(of: assistant.draft) { _, _ in assistant.saveDraft() }
    }
}

private struct AgentWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct ToolResultCard: View {
    @Environment(RecordStore.self) private var records
    let item: ChatItem
    let showDate: (String) -> Void
    private var result: [String: Any]? {
        guard let encoded = item.result, let snapshot = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] else { return nil }
        if let id = snapshot["operationID"] as? String, let current = try? records.operationResult(id) { return current }
        return snapshot
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result {
                let status = result["status"] as? String
                Label(status == "saved" ? "已保存" : status == "pending" ? "已存本机 · 待同步" : status == "failed" ? "保存失败" : "查询结果", systemImage: status == "saved" ? "checkmark.circle.fill" : "list.bullet.rectangle")
                    .font(.subheadline.bold()).foregroundStyle(status == "saved" ? Color.green : Color.accentColor)
                if let entries = result["entries"] as? [[String: Any]] {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        let kind = (entry["activity"] as? String).flatMap(RecordKind.init(rawValue:))
                        HStack {
                            Text(kind?.title ?? "运动记录")
                            Spacer()
                            Text("\((entry["amount"] as? Double ?? 0).formatted(.number.precision(.fractionLength(0...2)))) \(kind?.unitLabel ?? "")")
                        }
                        Text(entry["performedOn"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                        if let day = entry["performedOn"] as? String {
                            Button("在记录页查看与修改") { showDate(day) }.font(.caption)
                        }
                    }
                }
                if let totals = result["totals"] as? [String: Double] {
                    Divider()
                    Text("合计：俯卧撑 \((totals["pushups"] ?? 0).formatted()) 个 · 平板 \((totals["plank"] ?? 0).formatted()) 秒").font(.subheadline)
                }
                if let cached = result["cachedAt"] as? String { Text("缓存时间：\(cached)").font(.caption2).foregroundStyle(.secondary) }
                if let error = result["error"] as? String, !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                if let error = result["syncError"] as? String, !error.isEmpty { Text("使用本地缓存：\(error)").font(.caption).foregroundStyle(.orange) }
            } else {
                Label("工具未完成", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Text(item.text).font(.caption)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.15)))
    }
}
