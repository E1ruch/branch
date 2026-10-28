// swift-tools-version: 6.0
import PackageDescription

// The app is a thin shell over this package: every module is a target here,
// so dependencies are explicit, `internal` is the default boundary, and
// incremental builds only recompile what changed.
//
//   AppFeature ─▶ Communities/Auth/Feed/PostFeature ─▶ Stores, DesignSystem
//       │                │                                │
//       └──▶ Session ─▶ Networking ─▶ Core ◀──────────────┘
//
// Features never import each other: navigation goes through Core.Route.
let package = Package(
    name: "VetkaKit",
    defaultLocalization: "ru",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "AppFeature", targets: ["AppFeature"]),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Networking", dependencies: ["Core"]),
        .target(name: "Session", dependencies: ["Core", "Networking"]),
        .target(name: "DesignSystem"),
        .target(name: "Stores", dependencies: ["Core", "Networking", "DesignSystem"]),
        .target(name: "CommunitiesFeature", dependencies: ["Core", "Networking", "DesignSystem"]),
        .target(name: "AuthFeature", dependencies: ["Core", "Networking", "Session", "DesignSystem"]),
        .target(name: "FeedFeature", dependencies: ["Core", "Networking", "DesignSystem", "Stores"]),
        .target(name: "PostFeature", dependencies: ["Core", "Networking", "DesignSystem", "Stores"]),
        .target(name: "AppFeature", dependencies: ["Core", "Networking", "Session", "DesignSystem", "Stores",
                                                   "CommunitiesFeature", "AuthFeature", "FeedFeature", "PostFeature"]),

        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "NetworkingTests", dependencies: ["Networking"]),
        .testTarget(name: "SessionTests", dependencies: ["Session"]),
        .testTarget(name: "AuthFeatureTests", dependencies: ["AuthFeature"]),
        .testTarget(name: "FeedFeatureTests", dependencies: ["FeedFeature", "DesignSystem", "Stores"]),
        .testTarget(name: "StoresTests", dependencies: ["Stores"]),
        .testTarget(name: "PostFeatureTests", dependencies: ["PostFeature", "Stores"]),
    ]
)
