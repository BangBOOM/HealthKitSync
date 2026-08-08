import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = KeychainStore.read(account: "endpoint")
    @State private var token = KeychainStore.read(account: "token")
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Cloudflare Worker") {
                    TextField("https://example.workers.dev/v1/activities", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("上传 Token", text: $token)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Text("凭据只保存在本机 Keychain。Token 应只能上传活动，不能读取或删除数据库内容。")
                }
            }
            .navigationTitle("上传设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: { Text(errorMessage ?? "未知错误") }
        }
    }

    private func save() {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedEndpoint), url.scheme == "https" else {
            errorMessage = "请输入有效的 HTTPS URL"
            return
        }
        guard !trimmedToken.isEmpty else {
            errorMessage = "请输入上传 Token"
            return
        }
        let uploadURL = (url.path.isEmpty || url.path == "/")
            ? url.appendingPathComponent("v1/activities")
            : url
        do {
            endpoint = uploadURL.absoluteString
            token = trimmedToken
            try KeychainStore.save(endpoint, account: "endpoint")
            try KeychainStore.save(token, account: "token")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
