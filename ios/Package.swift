// swift-tools-version: 5.9
import PackageDescription

// Portable tests compile the same production parser and models as the iPhone app.
// Vision/camera integration remains in the Xcode-only test target.
let package = Package(
    name: "PrescriptionCore",
    products: [.library(name: "PrescriptionCore", targets: ["PrescriptionCore"])],
    targets: [
        .target(name: "PrescriptionCore", path: "Lifeblood", exclude: ["LifebloodApp.swift", "ProductService.swift", "SafetyEngine.swift", "Store.swift", "PrescriptionScanner.swift"], sources: ["Models.swift", "PrescriptionParser.swift"]),
        .testTarget(name: "PrescriptionCoreTests", dependencies: ["PrescriptionCore"], path: "LifebloodTests", exclude: ["SafetyTests.swift", "ProviderTests.swift"], sources: ["PrescriptionTests.swift"])
    ]
)
