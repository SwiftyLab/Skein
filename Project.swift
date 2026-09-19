import ProjectDescription

// Bundle identity and signing come from `Local.env`, which is gitignored so a
// team identifier never lands in the repository. Copy `Local.env.example` to
// start.
//
// The values arrive as TUIST_-prefixed environment variables, read through
// Tuist's `Environment`. That is the only mechanism available: Tuist evaluates
// manifests in a sandbox where `ProcessInfo.environment` is empty and reading
// `Local.env` from disk fails, so neither of the more obvious approaches works.
//
// `make generate` loads `Local.env` and exports these. Running `tuist generate`
// by hand without exporting them falls back to the defaults below — run
// `make config` to see what is actually resolved.

/// Treats an empty value as absent.
///
/// `export TUIST_BUNDLE_ID` in the Makefile exports the name even when
/// `Local.env` does not define it, so the variable arrives present but empty —
/// and `getString(default:)` only falls back when it is missing entirely, not
/// when it is blank.
func setting(_ value: String, default fallback: String) -> String {
    value.isEmpty ? fallback : value
}

let bundleId = setting(
    Environment.bundleId.getString(default: ""),
    default: "dev.soumyamahunt.skein")
let developmentTeam = Environment.developmentTeam.getString(default: "")

/// The share extension hands `.torrent` files to the app through an app group,
/// which requires the App Groups capability to be enabled for the identifier in
/// your developer account. Off by default, so a build does not demand account
/// setup; magnet links are shared without it either way.
let usesAppGroup = Environment.enableAppGroup.getString(default: "") == "1"
let appGroup = usesAppGroup ? "group.\(bundleId)" : ""

/// Signing settings, omitted entirely when no team is configured, so unsigned
/// builds on a fresh clone keep working.
let signingSettings: SettingsDictionary = developmentTeam.isEmpty
    ? [:]
    : [
        "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
        "CODE_SIGN_STYLE": "Automatic",
    ]

let project = Project(
    name: "Skein",
    packages: [
        // VLCKit plays the formats AVPlayer will not (MKV, AVI and friends),
        // which is most of what people stream. LGPL-2.1, so it stays
        // dynamically linked and relinkable.
        // Pinned by revision: VLCKit's 4.0 tags (4.0.0a21 and friends) are not
        // valid semver, so SwiftPM cannot resolve a version range against them,
        // and the 3.7.x line that is tagged semver predates the SPM manifest.
        .remote(url: "https://github.com/videolan/vlckit.git",
                requirement: .revision("440dc1df19d181b500ae414762671701d192bcf8")),
        // Xcode-native package integration, deliberately not Tuist's
        // `Tuist/Package.swift` + `.external(name:)` route: two open Tuist bugs
        // (#8056, #10296) mishandle local packages that wrap binary targets,
        // which is exactly this package's shape.
        .package(path: "."),
    ],
    settings: .settings(
        base: [
            // C++ interop is viral: TorrentKit enables it, so every dependent
            // target must too, including this app.
            "SWIFT_OBJC_INTEROP_MODE": "objcxx",
            "SWIFT_VERSION": "6.0",
        ]
    ),
    targets: [
        // iOS only: the extension exists to accept magnets and .torrent files
        // from Safari and Files. It does no networking — an extension's memory
        // limit is far tighter than an app's, and a libtorrent session would be
        // killed partway through a transfer.
        .target(
            name: "SkeinShare",
            destinations: [.iPhone, .iPad],
            product: .appExtension,
            bundleId: "\(bundleId).share",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Skein",
                // One source of truth for the group, read at runtime by both
                // targets rather than hardcoded in each.
                "SKAppGroup": .string(appGroup),
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
                    "NSExtensionAttributes": [
                        "NSExtensionActivationRule": [
                            "NSExtensionActivationSupportsWebURLWithMaxCount": 1,
                            "NSExtensionActivationSupportsFileWithMaxCount": 1,
                            "NSExtensionActivationSupportsText": true,
                        ]
                    ],
                ],
            ]),
            sources: ["App/ShareExtension/**"],
            entitlements: usesAppGroup
                ? .dictionary([
                    "com.apple.security.application-groups": .array([.string(appGroup)]),
                ])
                : nil,
            settings: .settings(base: signingSettings)
        ),

        .target(
            name: "Skein",
            destinations: [.iPhone, .iPad, .mac],
            product: .app,
            bundleId: bundleId,
            deploymentTargets: .multiplatform(iOS: "26.0", macOS: "26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Skein",
                "LSApplicationCategoryType": "public.app-category.utilities",
                // UIBackgroundModes and the BGTaskScheduler identifiers are
                // ignored on macOS, so one shared plist covers both platforms.
                "UIBackgroundModes": ["processing"],
                "BGTaskSchedulerPermittedIdentifiers": [
                    "$(PRODUCT_BUNDLE_IDENTIFIER).continued",
                    "$(PRODUCT_BUNDLE_IDENTIFIER).processing",
                ],
                "NSLocalNetworkUsageDescription":
                    "Skein discovers peers on your local network.",
                "SKAppGroup": .string(appGroup),
                "UILaunchScreen": [:],
                // Lets the system hand us magnet: links from Safari and others.
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "$(PRODUCT_BUNDLE_IDENTIFIER).magnet",
                        // skein: is how the share extension wakes the app after
                        // dropping a file in the shared container.
                        "CFBundleURLSchemes": ["magnet", "skein"],
                    ]
                ],
                // Read the .torrent where it sits rather than having iOS copy
                // it into our Inbox first: libtorrent parses it synchronously
                // inside add_torrent and never needs it again, so a copy would
                // be waste we then have to clean up. Declaring this also
                // silences the "doesn't declare whether it supports opening
                // files in place" warning.
                //
                // Not UISupportsDocumentBrowser — that is for apps whose main
                // interface is a document browser, which this is not.
                "LSSupportsOpeningDocumentsInPlace": true,

                // Opening .torrent files from Files, Mail and share sheets.
                "CFBundleDocumentTypes": [
                    [
                        "CFBundleTypeName": "BitTorrent Metainfo",
                        "LSHandlerRank": "Owner",
                        "LSItemContentTypes": ["org.bittorrent.torrent"],
                    ]
                ],
                "UTImportedTypeDeclarations": [
                    [
                        "UTTypeIdentifier": "org.bittorrent.torrent",
                        "UTTypeDescription": "BitTorrent Metainfo",
                        "UTTypeConformsTo": ["public.data"],
                        "UTTypeTagSpecification": [
                            "public.filename-extension": ["torrent"],
                            "public.mime-type": ["application/x-bittorrent"],
                        ],
                    ]
                ],
            ]),
            sources: [
                .glob("App/Sources/Shared/**"),
                .glob("App/Sources/iOS/**", compilationCondition: .when([.ios])),
                .glob("App/Sources/macOS/**", compilationCondition: .when([.macos])),
            ],
            resources: ["App/Resources/**"],
            // Left nil on purpose. Setting it makes Tuist emit its own
            // CODE_SIGN_ENTITLEMENTS, which would fight the [sdk=macosx*]
            // override below.
            entitlements: nil,
            dependencies: [
                .package(product: "TorrentKit"),
                .package(product: "TorrentFeeds"),
                .package(product: "VLCKit"),
                .target(name: "SkeinShare", condition: .when([.ios])),
            ],
            settings: .settings(base: signingSettings.merging([
                "CODE_SIGN_ENTITLEMENTS": usesAppGroup
                    ? "App/Entitlements/Skein-iOS-AppGroup.entitlements"
                    : "App/Entitlements/Skein-iOS.entitlements",
                "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "App/Entitlements/Skein-macOS.entitlements",
                "ENABLE_HARDENED_RUNTIME[sdk=macosx*]": "YES",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            ]) { _, new in new })
        ),
    ],
    additionalFiles: [
        "App/Entitlements/Skein-iOS.entitlements",
        "App/Entitlements/Skein-iOS-AppGroup.entitlements",
        "App/Entitlements/Skein-macOS.entitlements",
    ]
)
