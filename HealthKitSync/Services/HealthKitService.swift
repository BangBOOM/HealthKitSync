import CoreLocation
import Foundation
import HealthKit
import Observation

@MainActor
@Observable
final class HealthKitService {
    private let store = HKHealthStore()
    private(set) var workouts: [WorkoutSummary] = []
    private(set) var hasRequestedAuthorization = false
    private(set) var isLoading = false
    var errorMessage: String?

    init() {
        hasRequestedAuthorization = UserDefaults.standard.bool(forKey: "hasRequestedHealthAuthorization")
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "此设备不支持 Apple 健康"
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            hasRequestedAuthorization = true
            UserDefaults.standard.set(true, forKey: "hasRequestedHealthAuthorization")
            await loadWorkouts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadWorkouts() async {
        isLoading = true
        defer { isLoading = false }
        let start = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 500
        )
        do {
            workouts = try await descriptor.result(for: store).map {
                WorkoutSummary(id: $0.uuid, workout: $0)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareUpload(for summary: WorkoutSummary) async throws -> WorkoutUpload {
        async let heartRate = averageHeartRate(for: summary.workout)
        async let route = routeLocations(for: summary.workout)
        let distance = summary.distanceMeters
        let duration = max(0, Int(summary.duration.rounded()))
        let locations = try await route
        let elevation = elevationGain(from: locations)

        return WorkoutUpload(
            healthKitUUID: summary.id.uuidString,
            name: summary.title,
            workoutType: summary.workout.workoutActivityType.apiValue,
            startedAt: summary.workout.startDate,
            endedAt: summary.workout.endDate,
            distanceMeters: distance,
            movingTimeSeconds: duration,
            elevationGainMeters: elevation,
            averageHeartRate: try await heartRate,
            averageSpeedMetersPerSecond: distance.flatMap { duration > 0 ? $0 / Double(duration) : nil },
            routePolyline: PolylineEncoder.encode(locations),
            sourceDevice: summary.workout.device?.name
        )
    }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        if let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            types.insert(heartRate)
        }
        return types
    }

    private func averageHeartRate(for workout: HKWorkout) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
        let predicate = HKQuery.predicateForObjects(from: workout)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, error in
                if let error { continuation.resume(throwing: error); return }
                let unit = HKUnit.count().unitDivided(by: .minute())
                continuation.resume(returning: statistics?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func routeLocations(for workout: HKWorkout) async throws -> [CLLocation] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: HKSeriesType.workoutRoute(), predicate: predicate)],
            sortDescriptors: []
        )
        let routes = try await descriptor.result(for: store).compactMap { $0 as? HKWorkoutRoute }
        var allLocations: [CLLocation] = []
        for route in routes {
            allLocations += try await locations(for: route)
        }
        return allLocations.sorted { $0.timestamp < $1.timestamp }
    }

    private func locations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error { continuation.resume(throwing: error); return }
                collected.append(contentsOf: locations ?? [])
                if done { continuation.resume(returning: collected) }
            }
            store.execute(query)
        }
    }

    private func elevationGain(from locations: [CLLocation]) -> Double? {
        guard locations.count > 1 else { return nil }
        var gain = 0.0
        for pair in zip(locations, locations.dropFirst()) {
            let delta = pair.1.altitude - pair.0.altitude
            if delta > 1 { gain += delta }
        }
        return gain > 0 ? gain : nil
    }
}
