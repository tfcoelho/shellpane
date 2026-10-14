// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shellpane",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShellpaneUI", targets: ["ShellpaneUI"]),
        .library(name: "SFTPKit", targets: ["SFTPKit"]),
        .library(name: "SSHProcess", targets: ["SSHProcess"]),
        .library(name: "ShellpaneCore", targets: ["ShellpaneCore"]),
        .executable(name: "shellpane-askpass", targets: ["shellpane-askpass"]),
        .executable(name: "ShellpaneGallery", targets: ["ShellpaneGallery"]),
        .executable(name: "ShellpaneApp", targets: ["ShellpaneApp"]),
    ],
    targets: [
        .target(name: "SFTPKit"),
        .target(name: "SSHProcess", dependencies: ["SFTPKit"]),
        .target(name: "TransferKit", dependencies: ["SFTPKit"]),
        .target(name: "ShellpaneCore", dependencies: ["SSHProcess", "TransferKit"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "shellpane-askpass"),
        .target(name: "ShellpaneUI"),
        .executableTarget(name: "ShellpaneGallery", dependencies: ["ShellpaneUI"]),
        .executableTarget(name: "ShellpaneApp", dependencies: ["ShellpaneUI", "ShellpaneCore", "SFTPKit", "SSHProcess", "TransferKit", "shellpane-askpass"]),
        .testTarget(name: "SFTPKitTests", dependencies: ["SFTPKit"]),
        .testTarget(name: "TransferKitTests", dependencies: ["TransferKit", "SFTPKit"]),
        .testTarget(name: "ShellpaneCoreTests", dependencies: ["ShellpaneCore", "SSHProcess", "TransferKit"]),
        .testTarget(name: "SSHProcessTests", dependencies: ["SSHProcess", "SFTPKit", "shellpane-askpass"]),
    ]
)
