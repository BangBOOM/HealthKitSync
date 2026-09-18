import Network
import Observation

@MainActor
@Observable
final class NetworkStatus {
    private(set) var isOnline = false
    @ObservationIgnored private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "PersonalRecords.Connectivity"))
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
