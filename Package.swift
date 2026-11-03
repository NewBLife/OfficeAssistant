// swift-tools-version: 5.9
import PackageDescription
import Foundation

let developerPath = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Library/Developer/CommandLineTools"
let testingFrameworks = developerPath + "/Library/Developer/Frameworks"
let testingLibraries = developerPath + "/Library/Developer/usr/lib"
let testSwift: [SwiftSetting] = [.unsafeFlags(["-F", testingFrameworks])]
let testLinker: [LinkerSetting] = [.unsafeFlags(["-F", testingFrameworks, "-Xlinker", "-rpath", "-Xlinker", testingFrameworks, "-Xlinker", "-rpath", "-Xlinker", testingLibraries])]

let package = Package(
    name: "OfficeAssistant",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OfficeCore", targets: ["OfficeCore"]), .executable(name: "OfficeAssistant", targets: ["OfficeAssistant"])],
    dependencies: [.package(url: "https://github.com/microsoft/speech-sdk-spm", exact: "1.52.0")],
    targets: [
        .target(name: "OfficeCore"),
        .target(name: "OfficeDesktop", dependencies: ["OfficeCore", .product(name: "MicrosoftCognitiveServicesSpeech-macOS", package: "speech-sdk-spm")]),
        .executableTarget(name: "OfficeAssistant", dependencies: ["OfficeDesktop", "OfficeCore"], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "OfficeDesktopTests", dependencies: ["OfficeDesktop", "OfficeCore"], swiftSettings: testSwift, linkerSettings: testLinker),
        .testTarget(name: "OfficeCoreTests", dependencies: ["OfficeCore"], swiftSettings: testSwift, linkerSettings: testLinker)
    ]
)
