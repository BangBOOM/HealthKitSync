import SwiftUI

struct WorkoutListView: View {
    @Environment(HealthKitService.self) private var healthKit
    @Environment(UploadHistoryService.self) private var uploadHistory
    @State private var selected = Set<UUID>()
    @State private var statuses: [UUID: UploadStatus] = [:]
    @State private var showingSettings = false
    @State private var isUploading = false
    @State private var selectedCategory = WorkoutCategory.cycling

    private var filteredWorkouts: [WorkoutSummary] {
        healthKit.workouts.filter { selectedCategory.matches($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("运动类型", selection: $selectedCategory) {
                ForEach(WorkoutCategory.allCases) { category in
                    Text(category.title).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            List {
                if let message = uploadHistory.syncError {
                    Label(message, systemImage: "exclamationmark.icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredWorkouts) { summary in
                    let isUploaded = uploadHistory.contains(summary.id)
                    Button {
                        guard !isUploaded else { return }
                        if selected.contains(summary.id) { selected.remove(summary.id) }
                        else { selected.insert(summary.id) }
                    } label: {
                        WorkoutRow(
                            summary: summary,
                            selected: selected.contains(summary.id),
                            status: rowStatus(for: summary.id, isUploaded: isUploaded)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isUploaded)
                    .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            .listStyle(.plain)
            .animation(nil, value: selectedCategory)
            .overlay {
                if healthKit.isLoading {
                    ProgressView("读取运动记录…")
                } else if filteredWorkouts.isEmpty {
                    ContentUnavailableView(
                        "没有\(selectedCategory.title)记录",
                        systemImage: selectedCategory.systemImage
                    )
                }
            }
            .refreshable { await reload(forceHealthKit: true) }
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
        .sheet(isPresented: $showingSettings, onDismiss: {
            Task { await syncUploadHistory() }
        }) { SettingsView() }
        .task { await reload() }
    }

    private func reload(forceHealthKit: Bool = false) async {
        if forceHealthKit || healthKit.workouts.isEmpty { await healthKit.loadWorkouts() }
        await syncUploadHistory()
    }

    private func syncUploadHistory() async {
        await uploadHistory.refresh(localIDs: healthKit.workouts.map(\.id))
        selected.subtract(uploadHistory.uploadedIDs)
    }

    private func rowStatus(for id: UUID, isUploaded: Bool) -> UploadStatus {
        if isUploaded { return .alreadyUploaded }
        if let status = statuses[id] { return status }
        return uploadHistory.isSyncing ? .checking : .idle
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
            guard !uploadHistory.contains(workout.id) else {
                selected.remove(workout.id)
                continue
            }
            statuses[workout.id] = .preparing
            do {
                let payload = try await healthKit.prepareUpload(for: workout)
                statuses[workout.id] = .uploading
                try await client.upload(payload)
                statuses[workout.id] = .succeeded
                uploadHistory.markUploaded(workout.id)
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
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    if let distance = summary.distanceMeters {
                        Text(String(format: "%.2f km", distance / 1_000))
                    } else {
                        Text("— km")
                    }
                    Text(Duration.seconds(summary.duration).formatted(.time(pattern: .hourMinute)))
                }
                .font(.headline)
                Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                .foregroundStyle(.secondary)
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
        case .checking: ProgressView().controlSize(.small)
        case .preparing, .uploading: ProgressView()
        case .alreadyUploaded, .succeeded: Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.red)
        }
    }
}

private enum WorkoutCategory: String, CaseIterable, Identifiable {
    case cycling
    case running
    case hiking

    var id: Self { self }

    var title: String {
        switch self {
        case .cycling: "骑行"
        case .running: "跑步"
        case .hiking: "徒步"
        }
    }

    var systemImage: String {
        switch self {
        case .cycling: "bicycle"
        case .running: "figure.run"
        case .hiking: "figure.hiking"
        }
    }

    func matches(_ summary: WorkoutSummary) -> Bool {
        switch self {
        case .cycling: summary.workout.workoutActivityType == .cycling
        case .running: summary.workout.workoutActivityType == .running
        case .hiking: summary.workout.workoutActivityType == .hiking
        }
    }
}
