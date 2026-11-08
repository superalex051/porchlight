// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]
let mainActorByDefault: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "PorchLightKit",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "porchlight", targets: ["adcli"]),
        .executable(name: "porchlight-guardian", targets: ["adguardian"]),
        .library(name: "ADApp", targets: ["ADEngine", "ADUI", "ADInput", "ADIntegrations", "ADModel", "ADFoundation"]),
        // The session API for other apps, docs/session-api.md. Never the engine.
        .library(name: "PorchLightClient", targets: ["PorchLightClient"]),
    ],
    targets: [
        // Libraries
        .target(name: "CPrivateSPI"),
        .target(name: "ADFoundation", swiftSettings: strict),
        .target(name: "ADModel", swiftSettings: strict),
        .target(name: "ADSPI", dependencies: ["CPrivateSPI"], swiftSettings: strict),
        .target(name: "ADCommand", dependencies: ["ADModel"], swiftSettings: strict),
        .target(name: "ADIPC", dependencies: ["ADModel", "ADFoundation"], swiftSettings: strict),
        .target(name: "ADSafety", dependencies: ["ADModel", "ADFoundation"], swiftSettings: strict),
        .target(name: "ADDisplays", dependencies: ["ADModel", "ADFoundation", "ADSPI"], swiftSettings: strict),
        .target(
            name: "ADDisplayConfig",
            dependencies: ["ADDisplays", "ADSafety", "ADModel", "ADFoundation"],
            swiftSettings: strict
        ),
        .target(
            name: "ADVirtualScreens",
            dependencies: ["ADDisplays", "ADModel", "ADFoundation", "ADSPI"],
            swiftSettings: strict
        ),
        .target(
            name: "ADEngine",
            dependencies: [
                "ADCommand", "ADIPC", "ADSafety", "ADDisplays", "ADDisplayConfig",
                "ADVirtualScreens", "ADModel", "ADFoundation", "ADSPI", "ADIntegrations",
            ],
            swiftSettings: mainActorByDefault
        ),
        .target(name: "ADInput", dependencies: ["ADFoundation"], swiftSettings: strict),
        .target(name: "ADIntegrations", dependencies: ["ADFoundation"], swiftSettings: strict),
        .target(name: "ADUI", dependencies: ["ADModel"], swiftSettings: mainActorByDefault),
        .target(name: "PorchLightClient", dependencies: ["ADIPC", "ADModel", "ADFoundation"], swiftSettings: strict),

        // Executables
        .executableTarget(name: "adcli", dependencies: ["ADCommand", "ADIPC", "ADFoundation"], swiftSettings: strict),
        .executableTarget(
            name: "adguardian",
            dependencies: ["ADSafety", "ADDisplayConfig", "ADDisplays", "ADIPC", "ADModel", "ADFoundation"],
            swiftSettings: strict
        ),
        .executableTarget(name: "addevhost", dependencies: ["ADEngine", "ADFoundation"], swiftSettings: strict),

        // Tests
        .testTarget(name: "ADFoundationTests", dependencies: ["ADFoundation"], swiftSettings: strict),
        .testTarget(name: "ADModelTests", dependencies: ["ADModel"], swiftSettings: strict),
        .testTarget(name: "ADSPITests", dependencies: ["ADSPI"], swiftSettings: strict),
        .testTarget(name: "ADCommandTests", dependencies: ["ADCommand"], swiftSettings: strict),
        .testTarget(name: "ADIPCTests", dependencies: ["ADIPC"], swiftSettings: strict),
        .testTarget(name: "ADSafetyTests", dependencies: ["ADSafety"], swiftSettings: strict),
        .testTarget(name: "ADDisplaysTests", dependencies: ["ADDisplays"], swiftSettings: strict),
        .testTarget(name: "ADDisplayConfigTests", dependencies: ["ADDisplayConfig"], swiftSettings: strict),
        .testTarget(name: "ADVirtualScreensTests", dependencies: ["ADVirtualScreens"], swiftSettings: strict),
        .testTarget(name: "ADCLITests", dependencies: ["adcli"], swiftSettings: strict),
        .testTarget(name: "ADEngineTests", dependencies: ["ADEngine"], swiftSettings: strict),
        .testTarget(name: "ADInputTests", dependencies: ["ADInput"], swiftSettings: strict),
        .testTarget(name: "ADIntegrationsTests", dependencies: ["ADIntegrations"], swiftSettings: strict),
        .testTarget(name: "ADUITests", dependencies: ["ADUI"], swiftSettings: strict),
        .testTarget(
            name: "PorchLightClientTests",
            dependencies: ["PorchLightClient", "ADIPC", "ADModel"],
            swiftSettings: strict
        ),
    ]
)
