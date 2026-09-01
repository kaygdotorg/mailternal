// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MailternalCore",
    platforms: [.macOS(.v15)], // app target enforces macOS 26; package floor kept lower for Linux/CI parity
    products: [
        .library(name: "MailternalCore", targets: [
            "MailternalInterfaces", "MailternalIMAP", "MailternalMIME",
            "MailternalStore", "MailternalSanitizer", "MailternalSync",
        ]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-nio-imap", branch: "main"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.0"),
    ],
    targets: [
        .target(name: "MailternalInterfaces"),
        .target(name: "MailternalIMAP", dependencies: [
            "MailternalInterfaces",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOIMAP", package: "swift-nio-imap"),
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
            "MailternalSanitizer",
        ]),
        .testTarget(name: "MailternalIMAPTests", dependencies: [
            "MailternalIMAP",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOIMAP", package: "swift-nio-imap"),
        ]),
        .testTarget(name: "MailternalMIMETests", dependencies: ["MailternalMIME"],
                    resources: [.copy("Corpus")]),
        .testTarget(name: "MailternalStoreTests", dependencies: ["MailternalStore"]),
        .testTarget(name: "MailternalSanitizerTests", dependencies: ["MailternalSanitizer"]),
        .testTarget(name: "MailternalSyncTests", dependencies: [
            "MailternalSync", "MailternalStore", "MailternalIMAP", "MailternalInterfaces",
        ]),
    ]
)

#if os(macOS)
package.targets.append(contentsOf: [
    .target(
        name: "MailternalLive",
        dependencies: [
            "MailternalInterfaces",
            "MailternalIMAP",
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
])
#endif
