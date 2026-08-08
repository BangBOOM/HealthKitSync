import SwiftUI

struct WorkoutListView: View {
    @Environment(HealthKitService.self) private var healthKit
    @State private var selected = Set<UUID>()
    @State private var statuses: [UUID: UploadStatus] = [:]
    @State private var showingSettings = false
    @State private var isUploading = false

    var body: some View {
        List(healthKit.workouts) { summary in
            Button {
                if selected.contains(summary.id) { selected.remove(summary.id) }
                else { selected.insert(summary.id) }
            } label: {
                WorkoutRow(summary: summary, selected: selected.contains(summary.id), status: statuses[summary.id] ?? .idle)
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if healthKit.isLoading { ProgressView("读取运动记录…") }
            else if healthKit.workouts.isEmpty { ContentUnavailableView("没有运动记录", systemImage: "figure.run") }
        }
        .navigationTitle("选择运动")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("设置", systemImage: "gear") { showingSettings = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("上传 \(selected.count) 项") { Task { await uploadSelection() } }
                    .disabled(selected.isEmpty || isUploading)
            }
        }
        .refreshable { await healthKit.loadWorkouts() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .task { if healthKit.workouts.isEmpty { await healthKit.loadWorkouts() } }
    }

    private func uploadSelection() async {
        let token = KeychainStore.read(account: "token")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: KeychainStore.read(account: "endpoint")),
              !token.isEmpty else {
            showingSettings = true
            return
        }
        isUploading = true
        defer { isUploading = false }
        let client = UploadClient(endpoint: endpoint, token: token)
        for workout in healthKit.workouts where selected.contains(workout.id) {
            statuses[workout.id] = .preparing
            do {
                let payload = try await healthKit.prepareUpload(for: workout)
                statuses[workout.id] = .uploading
                try await client.upload(payload)
                statuses[workout.id] = .succeeded
                selected.remove(workout.id)
            } catch {
                statuses[workout.id] = .failed(error.localizedDescription)
            }
        }
    }
}

private struct WorkoutRow: View {
    let summary: WorkoutSummary
    let selected: Bool
    let status: UploadStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title).font(.headline)
                Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let distance = summary.distanceMeters {
                        Text(String(format: "%.2f km", distance / 1_000))
                    }
                    Text(Duration.seconds(summary.duration).formatted(.time(pattern: .hourMinute)))
                }
                .font(.caption)
                if case .failed(let message) = status {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            Spacer()
            statusView
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle: EmptyView()
        case .preparing, .uploading: ProgressView()
        case .succeeded: Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.red)
        }
    }
}
