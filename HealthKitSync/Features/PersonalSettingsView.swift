import SwiftUI

struct PersonalSettingsView: View {
    @Environment(RecordStore.self) private var records
    @Environment(AssistantStore.self) private var assistant
    @State private var settings = PersonalSettings.load()
    @State private var showingHealthSettings = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Apple 健康") {
                Button("健康运动上传设置", systemImage: "heart.text.clipboard") { showingHealthSettings = true }
            }
            Section("heatmap 数据服务") {
                TextField("HTTPS 基础地址", text: $settings.heatmapURL).keyboardType(.URL)
                SecureField("Fitness API Token", text: $settings.heatmapToken)
                TextField("Cloudflare Access Client ID（可选）", text: $settings.accessClientID)
                SecureField("Cloudflare Access Client Secret", text: $settings.accessClientSecret)
            }
            Section {
                TextField("API 基础地址，例如 https://example.com/v1", text: $settings.modelBaseURL).keyboardType(.URL)
                SecureField("模型 API Key", text: $settings.modelKey)
                TextField("模型名称", text: $settings.modelName)
            } header: { Text("文本助手") } footer: {
                Text("支持 Chat Completions 兼容接口和工具调用。Pi 在手机运行，模型通过你填写的接口调用。凭据保存在本机 Keychain。")
            }
            Section {
                Button("保存连接设置") { save() }.disabled(records.isSyncing || assistant.isBusy)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                NavigationLink("开源组件许可") {
                    ScrollView { Text(licenses).font(.caption.monospaced()).textSelection(.enabled).padding() }.navigationTitle("开源组件许可")
                }
            }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("设置")
        .sheet(isPresented: $showingHealthSettings) { SettingsView() }
    }

    private func save() {
        do {
            settings.heatmapURL = settings.heatmapURL.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.heatmapToken = settings.heatmapToken.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.modelBaseURL = settings.modelBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.modelName = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.modelKey = settings.modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.accessClientID = settings.accessClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.accessClientSecret = settings.accessClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            let configuration = try settings.recordConfiguration()
            try settings.save()
            try records.configure(configuration)
            assistant.resetRuntime(for: records)
            message = "设置已保存"
            Task { await records.sync() }
        } catch { message = error.localizedDescription }
    }

    private var licenses: String {
        guard let url = Bundle.main.url(forResource: "licenses", withExtension: "txt", subdirectory: "Agent") ?? Bundle.main.url(forResource: "licenses", withExtension: "txt") else { return "许可文件未打包" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "许可文件读取失败"
    }
}
