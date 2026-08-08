import Foundation

struct WorkoutUpload: Encodable, Sendable {
    let schemaVersion = 1
    let healthKitUUID: String
    let name: String
    let workoutType: String
    let startedAt: Date
    let endedAt: Date
    let distanceMeters: Double?
    let movingTimeSeconds: Int
    let elevationGainMeters: Double?
    let averageHeartRate: Double?
    let averageSpeedMetersPerSecond: Double?
    let routePolyline: String?
    let sourceDevice: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case healthKitUUID = "healthkit_uuid"
        case name
        case workoutType = "workout_type"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case distanceMeters = "distance_m"
        case movingTimeSeconds = "moving_time_s"
        case elevationGainMeters = "elevation_gain_m"
        case averageHeartRate = "average_heart_rate"
        case averageSpeedMetersPerSecond = "average_speed_mps"
        case routePolyline = "route_polyline"
        case sourceDevice = "source_device"
    }
}

enum UploadStatus: Equatable {
    case idle
    case checking
    case alreadyUploaded
    case preparing
    case uploading
    case succeeded
    case failed(String)
}
