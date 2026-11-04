// swift-tools-version: 5.10

import PackageDescription

// 标准 SwiftPM 构建：`swift build` / `swift test`（macOS 14+，无第三方依赖）。
// 历史：早期本机仅有 CommandLineTools 时清单链接器损坏、无法 swift build，
// 现已安装完整 Xcode，标准构建链路稳定；打包仍走 package.sh（Release 构建 + 手工组装 .app）。

let package = Package(
    name: "AgentAccountManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentAccountManager", targets: ["AgentAccountManager"]),
        .executable(name: "AgentAccountManagerWidget", targets: ["AgentAccountManagerWidget"]),
        .library(name: "Core", targets: ["Core"])
    ],
    targets: [
        .target(name: "Core"),
        .executableTarget(name: "AgentAccountManager", dependencies: ["Core"]),
        .executableTarget(name: "AgentAccountManagerWidget", dependencies: ["Core"]),
        .testTarget(name: "CoreTests", dependencies: ["Core", "AgentAccountManager"])
    ]
)
