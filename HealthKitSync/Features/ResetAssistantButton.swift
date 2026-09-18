import SwiftUI

struct ResetAssistantButton: View {
    @Environment(AssistantStore.self) private var assistant
    @Environment(RecordStore.self) private var records
    @State private var confirming = false
    @State private var failure: String?

    var body: some View {
        Button("重置上下文", systemImage: "arrow.counterclockwise") { confirming = true }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .disabled(assistant.isBusy)
            .accessibilityHint("清空当前对话，保留运动记录和草稿")
            .alert("重置当前对话？", isPresented: $confirming) {
                Button("重置", role: .destructive) {
                    Task {
                        do { try await assistant.resetConversation(records: records) }
                        catch { failure = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("当前聊天记录和模型上下文将清空，运动记录和未发送草稿会保留。")
            }
            .alert("重置未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }
}
