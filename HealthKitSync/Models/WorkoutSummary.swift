import Foundation
import HealthKit

struct WorkoutSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let workout: HKWorkout

    var title: String { workout.workoutActivityType.displayName }
    var startedAt: Date { workout.startDate }
    var duration: TimeInterval { workout.duration }
    var distanceMeters: Double? {
        workout.totalDistance?.doubleValue(for: .meter())
    }

    static func == (lhs: WorkoutSummary, rhs: WorkoutSummary) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension HKWorkoutActivityType {
    var isSupportedForUpload: Bool {
        switch self {
        case .cycling, .running, .hiking: true
        default: false
        }
    }

    var apiValue: String {
        switch self {
        case .running: "running"
        case .cycling: "cycling"
        case .walking: "walking"
        case .hiking: "hiking"
        case .swimming: "swimming"
        case .downhillSkiing, .crossCountrySkiing: "skiing"
        default: "other"
        }
    }

    var displayName: String {
        switch self {
        case .running: "跑步"
        case .cycling: "骑行"
        case .walking: "步行"
        case .hiking: "徒步"
        case .swimming: "游泳"
        case .downhillSkiing: "高山滑雪"
        case .crossCountrySkiing: "越野滑雪"
        default: "其他运动"
        }
    }
}
