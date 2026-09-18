// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersonalRecords",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PersonalRecords", targets: ["PersonalRecords"])],
    targets: [
        .target(name: "PersonalRecords", path: "HealthKitSync/Records"),
        .testTarget(name: "PersonalRecordsTests", dependencies: ["PersonalRecords"], path: "Tests/PersonalRecordsTests")
    ]
)
