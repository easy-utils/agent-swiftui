// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "agent-swiftui",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    dependencies: [
        // The typed agent client (pbandk-equivalent SwiftProtobuf messages +
        // the generated easy-rpc AgentServiceClient). Remote tag — no local paths.
        .package(url: "https://github.com/easy-utils/agent-sdk-swift.git", from: "0.18.0"),
        // The easy-rpc Swift core: URLSessionTransport + the composition root
        // (connect) and the proto3 JSON codec. The app imports it directly for
        // the transport it hands to the generated client.
        .package(url: "https://github.com/easy-utils/easy-rpc-swift.git", from: "3.0.0"),
        // Mature CommonMark/GFM renderer (cmark-gfm based) — replaces the raw
        // Text() rendering of message bodies. 2.4.1 supports macOS 12+/iOS 15+.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
        // Unified icon set shared with the Flutter / Compose / WebUI clients
        // (see tools/icons.py for the slot table). Pure SwiftUI Shapes — no
        // UIKit bindings — rendered at Lucide's 2pt stroke.
        .package(url: "https://github.com/ajaxjiang96/lucide-swift", from: "0.9.5"),
    ],
    targets: [
        .executableTarget(
            name: "agent-app",
            dependencies: [
                .product(name: "AgentSDK", package: "agent-sdk-swift"),
                .product(name: "easyRpc", package: "easy-rpc-swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "LucideSwift", package: "lucide-swift"),
            ],
            path: "Sources/agent-app",
            // Bundled so every client rasterizes the SAME glyphs: the two
            // Noto Sans SC / Noto Sans Mono statics produced by
            // tools/gen-fonts.py (Regular 400 + SemiBold 600). Registered with
            // CoreText at launch by Theme.registerBundledFonts().
            resources: [.process("Resources")]
        ),
        // Behavioural conformance tests for the message state machine. The
        // controller + models + AgentApi facade are SwiftUI-free, but the app
        // target links SwiftUI, so these run on Apple platforms (macOS CI); the
        // guard still asserts every scenario id is referenced here.
        .testTarget(
            name: "AgentAppTests",
            dependencies: ["agent-app"],
            path: "Tests/AgentAppTests",
            resources: [.copy("scenarios.json")]
        ),
    ]
)
