// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MailternalCore",
    platforms: [.macOS(.v15), .iOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "MailternalCore", targets: [
            "MailternalInterfaces", "MailternalIMAP", "MailternalSMTP", "MailternalMIME",
            "MailternalStore", "MailternalSanitizer", "MailternalSync",
        ]),
        .library(name: "MailternalAutomation", targets: ["MailternalAutomation"]),
        .library(name: "MailternalCompanion", targets: ["MailternalCompanion"]),
        .library(name: "MailternalWorkspace", targets: ["MailternalWorkspace"]),
        .library(name: "MailternalPairing", targets: ["MailternalPairing"]),
        .executable(name: "mailternal", targets: ["mailternal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.27.0"),
        .package(url: "https://github.com/kaygdotorg/swift-nio-imap", branch: "mailternal/line-buffer"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "MailternalInterfaces"),
        .target(name: "MailternalAutomation", dependencies: [
            "MailternalInterfaces", "MailternalWorkspace",
            .product(name: "NIO", package: "swift-nio", condition: .when(platforms: [.linux])),
            .product(name: "NIOTLS", package: "swift-nio", condition: .when(platforms: [.linux])),
            .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.linux])),
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]),
        .executableTarget(name: "mailternal", dependencies: ["MailternalAutomation", "MailternalInterfaces"]),
        .target(name: "MailternalCompanion"),
        .target(name: "MailternalWorkspace", dependencies: ["MailternalInterfaces"]),
        .target(name: "MailternalPairing", dependencies: [
            "MailternalInterfaces", "MailternalWorkspace",
        ]),
        .target(name: "MailternalTLS", dependencies: [
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .target(name: "MailternalIMAP", dependencies: [
            "MailternalInterfaces", "MailternalTLS",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOIMAP", package: "swift-nio-imap"),
        ]),
        .target(name: "MailternalSMTP", dependencies: [
            "MailternalInterfaces", "MailternalTLS",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .target(name: "MailternalMIME", dependencies: ["MailternalInterfaces"]),
        .target(name: "MailternalStore", dependencies: [
            "MailternalInterfaces",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "MailternalSanitizer", dependencies: [
            "MailternalInterfaces", "SwiftSoup",
        ]),
        .target(name: "MailternalSync", dependencies: [
            "MailternalInterfaces", "MailternalIMAP", "MailternalMIME", "MailternalStore",
            "MailternalSanitizer", "MailternalSMTP",
        ]),
        .testTarget(name: "MailternalAutomationTests", dependencies: [
            "MailternalAutomation", "MailternalInterfaces",
            .product(name: "NIO", package: "swift-nio", condition: .when(platforms: [.linux])),
            .product(name: "NIOEmbedded", package: "swift-nio", condition: .when(platforms: [.linux])),
        ]),
        .testTarget(name: "MailternalIMAPTests", dependencies: [
            "MailternalIMAP",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOIMAP", package: "swift-nio-imap"),
        ]),
        .testTarget(name: "MailternalSMTPTests", dependencies: [
            "MailternalSMTP", "MailternalInterfaces",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .testTarget(name: "MailternalMIMETests", dependencies: [
            "MailternalMIME", "MailternalInterfaces",
        ], resources: [.copy("Corpus")]),
        .testTarget(name: "MailternalStoreTests", dependencies: ["MailternalStore"]),
        .testTarget(name: "MailternalCompanionTests", dependencies: ["MailternalCompanion"]),
        .testTarget(name: "MailternalSanitizerTests", dependencies: ["MailternalSanitizer"]),
        .testTarget(name: "MailternalSyncTests", dependencies: [
            "MailternalSync", "MailternalStore", "MailternalIMAP", "MailternalInterfaces",
        ]),
    ]
)

#if os(macOS)
package.targets.append(contentsOf: [
    .testTarget(name: "MailternalWorkspaceTests", dependencies: [
        "MailternalWorkspace", "MailternalInterfaces",
    ]),
    .target(
        name: "MailternalLive",
        dependencies: [
            "MailternalInterfaces",
            "MailternalIMAP",
            "MailternalSMTP",
            "MailternalStore",
            "MailternalSync",
        ],
        path: "App/Sources",
        sources: [
            "Live/LiveMailFacade.swift",
            "Live/MailternalContainer.swift",
            "Live/LiveNotifications.swift",
            "Live/QAIMAPTrust.swift",
            "Live/QALaunch.swift",
            "Support/KeychainStore.swift",
        ]
    ),
    .testTarget(
        name: "MailternalLiveTests",
        dependencies: [
            "MailternalLive",
            "MailternalInterfaces",
            "MailternalIMAP",
            "MailternalSync",
            "MailternalStore",
        ]
    ),
    .testTarget(
        name: "MailternalPairingTests",
        dependencies: [
            "MailternalPairing",
            "MailternalInterfaces",
            "MailternalWorkspace",
        ]
    ),
])
#endif
