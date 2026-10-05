// swift-tools-version:5.9
import PackageDescription

// Homebrew libpq location (Apple Silicon). Adjust if libpq lives elsewhere.
let libpqInclude = "/opt/homebrew/opt/libpq/include"
let libpqLib = "/opt/homebrew/opt/libpq/lib"

// libpq's header must reach clang when it builds the CPostgres module that
// `shim.h` pulls in. A bare `-I` is a *Swift* module search path and never
// reaches clang (Swift 6.4's swiftbuild engine no longer propagates it to the
// clang module builds of a target's C dependencies), so forward it with -Xcc.
let libpqHeaderSearch: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(libpqInclude)"])]

let package = Package(
    name: "Tusk",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Tusk", targets: ["Tusk"]),      // GUI app
        .executable(name: "tuskcli", targets: ["tuskcli"]), // CLI (installed as `tusk`)
    ],
    dependencies: [
        // Embedded terminal (PTY + xterm emulator) for the Claude Code panel.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .systemLibrary(name: "CPostgres", path: "Sources/CPostgres"),

        // Shared core: models + the libpq-backed Database actor. No AppKit/SwiftUI,
        // so the CLI can link it without dragging in the GUI stack.
        .target(
            name: "TuskCore",
            dependencies: ["CPostgres"],
            swiftSettings: libpqHeaderSearch,
            linkerSettings: [.unsafeFlags(["-L", libpqLib])]
        ),

        // GUI application.
        .executableTarget(
            name: "Tusk",
            dependencies: ["TuskCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: libpqHeaderSearch,
            linkerSettings: [.unsafeFlags(["-L", libpqLib])]
        ),

        // Tiny CLI: `tusk mcp`, `tusk selfcheck`, `tusk doctor`.
        .executableTarget(
            name: "tuskcli",
            dependencies: ["TuskCore"],
            swiftSettings: libpqHeaderSearch,
            linkerSettings: [.unsafeFlags(["-L", libpqLib])]
        ),
    ]
)
