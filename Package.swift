// swift-tools-version: 6.2
import PackageDescription

// Compile definitions mirroring libtorrent's own CMakeLists.txt at v2.0.14.
// CMake computes these; building in-tree means we restate them here.
// DHT and encryption stay enabled by *omitting* TORRENT_DISABLE_DHT /
// TORRENT_DISABLE_ENCRYPTION.
//
// The OpenSSL trio matches what libtorrent's CMake sets when it finds OpenSSL,
// and gates HTTPS trackers, SSL torrents, and hashing via libcrypto. The
// xcframework is built by Scripts/build-openssl.sh, which lays headers out at
// include/openssl because that is what libtorrent includes.
let libtorrentDefines: [CXXSetting] = [
    .define("TORRENT_BUILDING_LIBRARY"),
    .define("TORRENT_USE_I2P", to: "0"),
    .define("BOOST_ASIO_ENABLE_CANCELIO"),
    .define("BOOST_ASIO_NO_DEPRECATED"),
    .define("BOOST_ASIO_HAS_STD_CHRONO"),
    .define("BOOST_EXCEPTION_DISABLE"),
    .define("BOOST_ALL_NO_LIB"),
    .define("TORRENT_USE_OPENSSL"),
    .define("TORRENT_USE_LIBCRYPTO"),
    .define("TORRENT_SSL_PEERS"),
]

let package = Package(
    name: "TorrentKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "TorrentKit", targets: ["TorrentKit"]),
        .library(name: "TorrentFeeds", targets: ["TorrentFeeds"]),
    ],
    dependencies: [
        // RSS/Atom parsing for the auto-download feature.
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "10.0.0"),
    ],
    targets: [
        // libtorrent itself, compiled from the pinned submodule.
        // `sources: ["src"]` recurses, picking up src/kademlia and src/ed25519.
        // try_signal's example.cpp/test.cpp define main(), so name its two real
        // sources explicitly rather than globbing the directory.
        // Built by Scripts/build-openssl.sh. Static libssl and libcrypto are
        // merged into one library, since an xcframework slice carries only one.
        .binaryTarget(
            name: "COpenSSL",
            path: "Vendor/openssl/OpenSSL.xcframework"
        ),

        .target(
            name: "Clibtorrent",
            dependencies: ["COpenSSL"],
            path: "Vendor/libtorrent",
            // Extensionless, so SwiftPM would otherwise try to compile it.
            exclude: ["src/ed25519/LICENSE"],
            sources: [
                "src",
                "deps/try_signal/try_signal.cpp",
                "deps/try_signal/signal_error_code.cpp",
            ],
            publicHeadersPath: "include",
            cxxSettings: libtorrentDefines + [
                .headerSearchPath("deps/try_signal"),
                .headerSearchPath("../boost"),
            ],
            // Mirrors libtorrent's CMakeLists `if (APPLE)` branch. Needed by
            // ip_notifier.cpp, which watches for network interface changes.
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),

        // Our narrow C++ facade. Every entry point catches all exceptions:
        // Swift cannot catch C++ exceptions, so one escaping would abort.
        .target(
            name: "TorrentBridge",
            dependencies: ["Clibtorrent"],
            path: "Sources/TorrentBridge",
            publicHeadersPath: "include",
            cxxSettings: libtorrentDefines + [
                .headerSearchPath("../../Vendor/boost"),
                // SwiftPM synthesises an umbrella modulemap over libtorrent's
                // include/ directory. libtorrent includes its warning-pragma
                // headers *inside* namespaces and classes, which clang reports
                // as a nested redundant module import — an error under modules.
                // The includes are correct; only the module framing objects.
                .unsafeFlags(["-Wno-modules-import-nested-redundant"]),
            ]
        ),

        .target(
            name: "TorrentKit",
            dependencies: ["TorrentBridge"],
            path: "Sources/TorrentKit",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),

        // Kept separate from TorrentKit: feeds are plain Swift with no C++
        // involvement, so this target needs no interop mode and builds fast.
        .target(
            name: "TorrentFeeds",
            dependencies: [
                "TorrentKit",
                .product(name: "FeedKit", package: "FeedKit"),
            ],
            path: "Sources/TorrentFeeds",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),

        .testTarget(
            name: "TorrentKitTests",
            dependencies: ["TorrentKit"],
            path: "Tests/TorrentKitTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),

        .testTarget(
            name: "TorrentFeedsTests",
            dependencies: ["TorrentFeeds"],
            path: "Tests/TorrentFeedsTests",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
