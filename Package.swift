// swift-tools-version: 5.8
import PackageDescription
let package = Package(name: "FrameForge", platforms: [.macOS(.v13)], products: [.executable(name: "FrameForge", targets: ["FrameForge"])], targets: [.executableTarget(name: "FrameForge")])
