import SwiftUI

struct AuthorizationView: View {
    @Environment(HealthKitService.self) private var healthKit
    @State private var requesting = false

    var body: some View {
        ContentUnavailableView {
            Label("连接 Apple 健康", systemImage: "heart.text.clipboard")
        } description: {
            Text("读取你选择的运动、心率和运动路线。App 不会修改健康数据。")
        } actions: {
            Button("授权读取") {
                requesting = true
                Task {
                    await healthKit.requestAuthorization()
                    requesting = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(requesting)
        }
        .navigationTitle("HealthKit Sync")
        .alert("无法访问健康数据", isPresented: errorBinding) {
            Button("好") { healthKit.errorMessage = nil }
        } message: {
            Text(healthKit.errorMessage ?? "未知错误")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { healthKit.errorMessage != nil }, set: { if !$0 { healthKit.errorMessage = nil } })
    }
}

