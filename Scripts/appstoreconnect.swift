#!/usr/bin/env swift
// Releases the iOS app through EU alternative distribution (AltStore PAL). Skein never goes on the App Store,
// so every version is submitted with review type NOTARIZATION. Safe to re-run: anything already done is skipped.
//
// Usage:
//   swift Scripts/appstoreconnect.swift setup [--dry-run]      # bundle IDs, then waits for the app record (once)
//   swift Scripts/appstoreconnect.swift listing [--dry-run]    # app info, age rating, version text, review notes
//   swift Scripts/appstoreconnect.swift screenshots [--dry-run] # AppStore/screenshots → the version's screenshots
//   swift Scripts/appstoreconnect.swift encryption [--dry-run]  # file the export compliance answers (once)
//   swift Scripts/appstoreconnect.swift beta [--dry-run]        # internal TestFlight group + newest build's notes
//   swift Scripts/appstoreconnect.swift beta-check             # does TestFlight need a fresh build before expiry?
//   swift Scripts/appstoreconnect.swift notarize [--dry-run]   # latest build → version → submit for notarization
//   swift Scripts/appstoreconnect.swift status                 # version, review and ADP state
//   swift Scripts/appstoreconnect.swift altstore-register      # get an AltStore PAL marketplace token (once)
//   swift Scripts/appstoreconnect.swift release-check          # is there a release AltStore has finished? (no waiting)
//   swift Scripts/appstoreconnect.swift release [--dry-run]    # GitHub release of the notarized ADP + AltStore source
//
// By hand only (no API): App Privacy, and adding the marketplace token under
// Users and Access › Integrations › Marketplace.
//
// Export compliance is answered from `encryption` below, a legal declaration: change it only if the answers change.
//
// Credentials come from Local.env (see Local.env.example), or from the environment in CI, where ASC_PRIVATE_KEY
// can hold the key itself instead of ASC_PRIVATE_KEY_PATH. `release` also needs an authenticated `gh`.

import CryptoKit
import Foundation

// MARK: - Command line and config

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first { !$0.hasPrefix("-") } ?? ""
let dryRun = arguments.contains("--dry-run")
let locale = "en-US"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

guard ["setup", "listing", "screenshots", "encryption", "beta", "beta-check", "notarize", "status", "altstore-register", "release-check", "release"].contains(command) else {
    fail("Usage: swift Scripts/appstoreconnect.swift <setup|listing|screenshots|encryption|beta|beta-check|notarize|status|altstore-register|release-check|release> [--dry-run]")
}

let envKeys = ["TUIST_BUNDLE_ID", "ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_PRIVATE_KEY_PATH", "ASC_PRIVATE_KEY", "GITHUB_REPOSITORY", "TUIST_ENABLE_APP_GROUP",
               "ENCRYPTION_FRANCE_DOCUMENT", "TUIST_EXPORT_COMPLIANCE_CODE",
               "DEVELOPER_NAME", "SUPPORT_URL", "PRIVACY_POLICY_URL", "PATREON_URL", "BETA_RENEW_DAYS",
               "REVIEW_FIRST_NAME", "REVIEW_LAST_NAME", "REVIEW_EMAIL", "REVIEW_PHONE",
               "ALTSTORE_DEVELOPER_ID", "ALTSTORE_EMAIL"]

func loadEnv(_ path: String = "Local.env") -> [String: String] {
    var values: [String: String] = [:]
    if let text = try? String(contentsOfFile: path, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            values[key] = value
        }
    }
    // Real environment variables win over the file, as they do in the Makefile.
    for key in envKeys {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { values[key] = v }
    }
    return values
}

let env = loadEnv()
func setting(_ key: String) -> String { env[key] ?? "" }
// The bundle id is the one value every command needs; it comes from Local.env like the build's.
let bundleID = setting("TUIST_BUNDLE_ID")
guard !bundleID.isEmpty else { fail("Set TUIST_BUNDLE_ID in Local.env (or the environment) to the app's bundle id.") }

/// Who publishes Skein and where its pages live. Only commands that publish text need these.
let developerName = setting("DEVELOPER_NAME")
let supportURL = setting("SUPPORT_URL")
let privacyPolicyURL = setting("PRIVACY_POLICY_URL")

func requireSettings(_ keys: [String]) throws {
    let missing = keys.filter { setting($0).isEmpty }
    guard missing.isEmpty else { throw APIError(status: 0, detail: "set \(missing.joined(separator: ", ")) in Local.env (or the environment)") }
}

// Values the repository already defines, read from there rather than repeated here.
let manifest = (try? String(contentsOfFile: "Project.swift", encoding: .utf8)) ?? ""

/// The first capture group of `pattern` in Project.swift.
func fromManifest(_ pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)),
          let range = Range(match.range(at: 1), in: manifest) else { return nil }
    return String(manifest[range])
}

/// The light-appearance accent colour from the asset catalog, as #RRGGBB.
func accentColor() -> String {
    let url = URL(fileURLWithPath: "App/Resources/Assets.xcassets/AccentColor.colorset/Contents.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let color = (json["colors"] as? [[String: Any]])?.first(where: { $0["appearances"] == nil })?["color"] as? [String: Any],
          let components = color["components"] as? [String: String] else { return "#000000" }
    let hex = ["red", "green", "blue"].map { key -> String in
        let value = Double(components[key] ?? "0") ?? 0
        return String(format: "%02X", Int((value <= 1 ? value * 255 : value).rounded()))
    }
    return "#" + hex.joined()
}


// MARK: - What to create

// Store listing (en-US). Notarization still needs the App Store metadata, though none of it is shown on the App
// Store. Limits: subtitle 30, keywords 100, promotional text 170, description 4000 characters.
let listing = (
    subtitle: "BitTorrent, done natively",
    promotionalText: "Stream while it downloads, follow RSS feeds, and manage every file, peer and tracker.",
    keywords: "torrent,bittorrent,magnet,download,libtorrent,rss,stream,p2p,seed,peer",
    description: """
    Skein is a native BitTorrent client for iPhone and iPad, built on libtorrent.

    DOWNLOAD
    • Add torrents from magnet links or .torrent files, from Safari, Files or the share sheet.
    • Pause, resume, recheck and reorder; downloads carry on in the background while iOS allows.
    • Choose which files to fetch and set per-torrent speed limits.

    STREAM
    • Play video while it downloads: Skein fetches pieces in playback order, and plays MKV, AVI and other formats.

    FEEDS
    • Subscribe to RSS and Atom feeds and download new items automatically with include, exclude or regex rules.

    IN CONTROL
    • Peers, trackers and piece availability for every torrent.
    • DHT, local peer discovery, peer exchange, UPnP and NAT-PMP, protocol encryption.
    • SOCKS and HTTP proxies, IP blocklists and active-download limits.

    Skein contains no content and no search. Only download and share files you have the right to.

    Privacy Policy: \(privacyPolicyURL)
    """,
    copyright: "\(Calendar.current.component(.year, from: Date())) \(developerName)",
    category: "UTILITIES",
    reviewNotes: """
    Skein is a BitTorrent client distributed only through alternative marketplaces. It ships no content and no search.
    To try it, add any legal torrent, e.g. an Ubuntu image from https://ubuntu.com/download/alternative-downloads (tap a .torrent link in Safari and choose Skein, or paste a magnet link with the + button). A video torrent can be played while it downloads from its detail screen.
    The processing background mode keeps active transfers going after the user leaves the app; nothing runs when no transfer is active. Local network access is used to find peers on the same network (Local Service Discovery).
    """
)

/// Age rating answers. Only questions App Store Connect currently asks are sent; anything else is listed for review.
/// Unrestricted web access is yes: the app downloads whatever a torrent points at, which is the honest answer.
let ageRating: JSON = [
    "alcoholTobaccoOrDrugUseOrReferences": "NONE", "contests": "NONE", "gamblingSimulated": "NONE",
    "horrorOrFearThemes": "NONE", "matureOrSuggestiveThemes": "NONE", "medicalOrTreatmentInformation": "NONE",
    "profanityOrCrudeHumor": "NONE", "sexualContentGraphicAndNudity": "NONE", "sexualContentOrNudity": "NONE",
    "violenceCartoonOrFantasy": "NONE", "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE", "gunsOrOtherWeapons": "NONE",
    "gambling": false, "unrestrictedWebAccess": true, "lootBox": false,
    "advertising": false, "messagingAndChat": false, "userGeneratedContent": false,
    "parentalControls": false, "ageAssurance": false, "healthOrWellnessTopics": false,
    "socialMedia": false, "socialMediaAgeRestricted": false,
]

// AltStore PAL source (https://faq.altstore.io/developers/make-a-source). It is committed at AltStore/source.json and
// served from the repository's raw files; `release` adds each version, whose files are a GitHub release's assets.
let source = (
    name: "Skein",
    identifier: "\(bundleID).source",
    tintColor: accentColor(),
    category: "utilities",
    // From Project.swift; AltStore shows these before install.
    entitlements: [String](),
    privacy: fromManifest(#""NSLocalNetworkUsageDescription":\s*"([^"]+)""#).map { ["NSLocalNetworkUsageDescription": $0] } ?? [:]
)
let sourceFile = URL(fileURLWithPath: "AltStore/source.json")
let appIcon = URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset/icon-universal-1024x1024@1x.png")
let publishDir = URL(fileURLWithPath: "build/altstore")
/// Folders written by Scripts/screenshots.sh, and the App Store Connect slot each fills. APP_IPHONE_67 is the
/// 6.7"/6.9" slot and APP_IPAD_PRO_3GEN_129 the 13" one, the two sizes App Store Connect requires.
/// Export compliance answers. Skein bundles OpenSSL (TLS, hashing) and libtorrent's protocol encryption (RC4,
/// Diffie-Hellman): standard, published algorithms implemented in the app rather than Apple's, nothing proprietary.
let encryption = (
    proprietary: false,
    thirdParty: true,
    // Not declared for France, so no ANSSI declaration is needed. Changing this to true needs
    // ENCRYPTION_FRANCE_DOCUMENT and a new declaration (`make encryption` files one with the new answers).
    france: false,
    // At most 300 characters.
    description: "BitTorrent client using only standard encryption: TLS via bundled OpenSSL for HTTPS trackers and SSL torrents, SHA hashes to verify downloads, and BitTorrent protocol encryption (RC4, Diffie-Hellman) via libtorrent to obfuscate peer traffic. No proprietary cryptography."
)
/// App Store Connect only takes a declaration when documents are due: proprietary cryptography, or standard
/// cryptography distributed in France. Otherwise the encryption is exempt from documentation, and Apple's guidance is
/// to answer ITSAppUsesNonExemptEncryption = NO, which Project.swift does for every build.
let needsDeclaration = encryption.proprietary || (encryption.thirdParty && encryption.france)

/// Internal TestFlight testing. Limits: "What to Test" 4000 characters.
let beta = (
    group: "Team",
    whatToTest: """
    Try adding a torrent from a magnet link and from a .torrent file shared from Files or Safari, streaming a video while it downloads, an RSS feed with a download rule, and leaving the app with downloads running (⋯ › Keep Downloading in Background).
    """
)

let screenshotSets = [("iphone", "APP_IPHONE_67"), ("ipad", "APP_IPAD_PRO_3GEN_129")]
let screenshotsDir = URL(fileURLWithPath: "AppStore/screenshots")

func screenshotFiles(_ folder: String) -> [URL] {
    let dir = screenshotsDir.appendingPathComponent(folder)
    return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

/// Where VLCKit's LGPL-2.1 source and license live, at the revision Project.swift pins. Linked from every release.
let vlcKitSource = "https://github.com/videolan/vlckit/tree/" + (fromManifest(#"vlckit\.git",\s*requirement:\s*\.revision\("([0-9a-f]+)"\)"#) ?? "master")


if dryRun {
    print("Plan for \(bundleID) (dry run, nothing is sent):")
    let phone = setting("REVIEW_PHONE")
    if command == "setup" {
        print("  bundle IDs: \(bundleID) (universal), \(bundleID).share (iOS)" + (setting("TUIST_ENABLE_APP_GROUP") == "1" ? ", both with App Groups" : ""))
        print("  app record: checked; if missing, opens App Store Connect with the values to enter and waits for it")
    } else if command == "listing" {
        print("  subtitle (\(listing.subtitle.count)/30): \(listing.subtitle)")
        print("  keywords (\(listing.keywords.count)/100): \(listing.keywords)")
        print("  promotional text (\(listing.promotionalText.count)/170)")
        print("  description (\(listing.description.count)/4000)")
        print("  category \(listing.category) · support \(supportURL.isEmpty ? "MISSING (SUPPORT_URL)" : supportURL) · privacy \(privacyPolicyURL.isEmpty ? "MISSING (PRIVACY_POLICY_URL)" : privacyPolicyURL)")
        print("  copyright \"\(developerName.isEmpty ? "MISSING (DEVELOPER_NAME)" : listing.copyright)\", content rights: no third-party content")
        print("  age rating: unrestricted web access yes, everything else none")
        print("  version review type NOTARIZATION (alternative distribution only), released once notarized")
        print("  review contact \(setting("REVIEW_FIRST_NAME")) \(setting("REVIEW_LAST_NAME")), \(setting("REVIEW_EMAIL")), phone \(phone.isEmpty ? "MISSING (set REVIEW_PHONE in Local.env)" : phone)")
    } else if command == "screenshots" {
        for (folder, displayType) in screenshotSets {
            let files = screenshotFiles(folder)
            print("  \(displayType): " + (files.isEmpty ? "MISSING (run `make screenshots`)" : files.map(\.lastPathComponent).joined(separator: ", ")))
        }
        print("  each slot is replaced only when its files changed")
    } else if command == "encryption" {
        print("  answers: proprietary cryptography \(encryption.proprietary), third-party (standard) cryptography \(encryption.thirdParty), available in France \(encryption.france)")
        if encryption.france {
            let document = setting("ENCRYPTION_FRANCE_DOCUMENT")
            print("  French declaration: " + (document.isEmpty ? "MISSING (set ENCRYPTION_FRANCE_DOCUMENT)" : document))
        }
        print(needsDeclaration
              ? "  files a declaration, reusing a pending or approved one with the same answers"
              : "  no declaration: these answers need no documentation, so builds answer ITSAppUsesNonExemptEncryption = NO")
    } else if command == "beta" {
        print("  internal group \"\(beta.group)\" with access to every build (no review; testers are App Store Connect users)")
        print("  newest processed build: export compliance if unanswered, \"What to Test\" (\(beta.whatToTest.count)/4000)")
    } else if command == "notarize" {
        print("  latest processed build → editable version (created if needed, version number taken from the build)")
        print("  export compliance from the declaration `make encryption` filed, if the build doesn't carry a code")
        print("  review type NOTARIZATION, build attached, added to a review submission and submitted")
    } else if command == "release" {
        print("  newest version with an ADP → AltStore processes it → unzip into \(publishDir.relativePath)/v<version>-<build>/")
        print("  GitHub release v<version>-<build> in this repository, one asset per ADP file (skipped if it exists)")
        print("  \(sourceFile.relativePath): version added with assetURLs, served from raw.githubusercontent.com on main")
        print("  source: \(source.identifier), developer \(developerName.isEmpty ? "MISSING (DEVELOPER_NAME)" : developerName), tint \(source.tintColor), permissions \(source.privacy)")
        print("  release notes link VLCKit's source at \(vlcKitSource)")
        print("  Patreon link on the source: \(setting("PATREON_URL").isEmpty ? "none (PATREON_URL unset)" : setting("PATREON_URL"))")
    } else {
        print("  nothing to plan for \(command)")
    }
    exit(0)
}

// MARK: - AltStore registration (no App Store Connect key needed)

@discardableResult
func request(_ method: String, _ url: URL, json body: JSON? = nil, headers: [String: String] = [:]) async throws -> (status: Int, data: Data) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

if command == "altstore-register" {
    let developerID = setting("ALTSTORE_DEVELOPER_ID"), email = setting("ALTSTORE_EMAIL")
    guard !developerID.isEmpty, !email.isEmpty else {
        fail("Set ALTSTORE_DEVELOPER_ID (App Store Connect › your name › Edit Profile › Developer ID) and ALTSTORE_EMAIL in Local.env.")
    }
    let (status, data) = try await request("POST", URL(string: "https://api.altstore.io/register")!, json: ["developerID": developerID, "email": email])
    guard (200..<300).contains(status), let json = try? JSONSerialization.jsonObject(with: data) as? JSON, let token = json["token"] as? String else {
        fail("AltStore registration failed (HTTP \(status)): \(String(decoding: data, as: UTF8.self))")
    }
    print("""
    AltStore PAL marketplace token (expires \(json["expiration"] as? String ?? "within 7 days")):

    \(token)

    Add it in App Store Connect › Users and Access › Integrations › Marketplace › +, select Skein, and choose
    "Yes, send notifications". This needs the Account Holder or an Admin, and can't be done with an API key.
    """)
    exit(0)
}

guard !setting("ASC_ISSUER_ID").isEmpty, !setting("ASC_KEY_ID").isEmpty,
      !setting("ASC_PRIVATE_KEY_PATH").isEmpty || !setting("ASC_PRIVATE_KEY").isEmpty else {
    fail("Fill in ASC_ISSUER_ID, ASC_KEY_ID and ASC_PRIVATE_KEY_PATH in Local.env first.")
}
let issuer = setting("ASC_ISSUER_ID"), keyID = setting("ASC_KEY_ID")
let pem: String
if !setting("ASC_PRIVATE_KEY").isEmpty {
    pem = setting("ASC_PRIVATE_KEY")
} else {
    let expandedKeyPath = (setting("ASC_PRIVATE_KEY_PATH") as NSString).expandingTildeInPath
    guard let contents = try? String(contentsOfFile: expandedKeyPath, encoding: .utf8) else {
        fail("Couldn't read the private key at \(expandedKeyPath).")
    }
    pem = contents
}
let privateKey: P256.Signing.PrivateKey
do { privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem) } catch { fail("That .p8 file isn't a valid App Store Connect key: \(error)") }

// MARK: - API client

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// Short-lived ES256 token, as App Store Connect requires.
func token() throws -> String {
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let payload = try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"])
    let signingInput = "\(base64URL(header)).\(base64URL(payload))"
    let signature = try privateKey.signature(for: Data(signingInput.utf8))
    return "\(signingInput).\(base64URL(signature.rawRepresentation))"
}

struct APIError: Error, CustomStringConvertible {
    let status: Int
    let detail: String
    var description: String { status == 0 ? detail : "HTTP \(status): \(detail)" }
}

typealias JSON = [String: Any]

@discardableResult
func api(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> JSON {
    let url = path.hasPrefix("https://") ? URL(string: path)! : URL(string: "https://api.appstoreconnect.apple.com\(path)")!
    for attempt in 1...4 {
        let (status, data) = try await request(method, url, json: body, headers: ["Authorization": "Bearer \(try token())"])
        // Back off politely if App Store Connect rate-limits us.
        if status == 429, attempt < 4 {
            try await Task.sleep(for: .seconds(Double(attempt) * 5))
            continue
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
        guard (200..<300).contains(status) else {
            let errors = (json["errors"] as? [JSON] ?? []).map { "\($0["title"] ?? ""): \($0["detail"] ?? "")" }
            throw APIError(status: status, detail: errors.isEmpty ? String(decoding: data, as: UTF8.self) : errors.joined(separator: "; "))
        }
        return json
    }
    throw APIError(status: 429, detail: "rate limited")
}

/// Follows `links.next` to collect every page of a list.
func all(_ path: String) async throws -> (data: [JSON], included: [JSON]) {
    var data: [JSON] = [], included: [JSON] = []
    var next: String? = path
    while let page = next {
        let json = try await api("GET", page)
        data += json["data"] as? [JSON] ?? []
        included += json["included"] as? [JSON] ?? []
        next = (json["links"] as? JSON)?["next"] as? String
    }
    return (data, included)
}

func resource(_ type: String, id: String) -> JSON { ["data": ["type": type, "id": id]] }
func items(_ json: JSON) -> [JSON] { json["data"] as? [JSON] ?? [] }
func attribute(_ item: JSON, _ key: String) -> Any? { (item["attributes"] as? JSON)?[key] }
func relatedID(_ item: JSON, _ relationship: String) -> String? {
    (((item["relationships"] as? JSON)?[relationship] as? JSON)?["data"] as? JSON)?["id"] as? String
}
func createdID(_ json: JSON) -> String { (json["data"] as? JSON)?["id"] as? String ?? "" }

var failures: [String] = []

@MainActor
func attempt(_ label: String, _ work: () async throws -> Void) async {
    do { try await work() } catch {
        failures.append("\(label): \(error)")
        print("  ✗ \(label): \(error)")
    }
}

// MARK: - Setup (bundle IDs and app record)

/// The app record's fields. App Store Connect has no API to create apps, so these are typed into its New App form.
let appRecord = (name: "Skein", sku: "skein", language: "English (U.S.)")

/// Registers an identifier unless it exists. The filter matches prefixes, so the identifier is compared exactly.
@MainActor
func registerBundleID(_ identifier: String, name: String, platform: String) async throws -> String {
    let found = items(try await api("GET", "/v1/bundleIds?filter%5Bidentifier%5D=\(identifier)&limit=200"))
    if let existing = found.first(where: { attribute($0, "identifier") as? String == identifier }), let id = existing["id"] as? String {
        print("  = \(identifier) (\(attribute(existing, "platform") as? String ?? "?"))")
        return id
    }
    let id = createdID(try await api("POST", "/v1/bundleIds", [
        "data": ["type": "bundleIds", "attributes": ["identifier": identifier, "name": name, "platform": platform]],
    ]))
    print("  + \(identifier) (\(platform))")
    return id
}

@MainActor
func setUpApp() async throws {
    print("→ Bundle IDs…")
    // Universal, because the Mac app ships under the same identifier via Developer ID.
    let appBundle = try await registerBundleID(bundleID, name: "Skein", platform: "UNIVERSAL")
    let shareBundle = try await registerBundleID("\(bundleID).share", name: "Skein Share", platform: "IOS")
    if setting("TUIST_ENABLE_APP_GROUP") == "1" {
        // The group itself has no API; Xcode registers it on the first signed archive.
        for (identifier, id) in [(bundleID, appBundle), ("\(bundleID).share", shareBundle)] {
            await attempt("App Groups on \(identifier)") {
                let current = items(try await api("GET", "/v1/bundleIds/\(id)/bundleIdCapabilities?limit=200"))
                guard !current.contains(where: { attribute($0, "capabilityType") as? String == "APP_GROUPS" }) else { return }
                try await api("POST", "/v1/bundleIdCapabilities", [
                    "data": ["type": "bundleIdCapabilities", "attributes": ["capabilityType": "APP_GROUPS"],
                             "relationships": ["bundleId": resource("bundleIds", id: id)]],
                ])
                print("  + App Groups on \(identifier)")
            }
        }
    }

    print("→ App record…")
    let lookup = "/v1/apps?filter%5BbundleId%5D=\(bundleID)"
    if let app = items(try await api("GET", lookup)).first {
        print("  = \"\(attribute(app, "name") as? String ?? "?")\" (\(app["id"] as? String ?? "?"))")
        return
    }
    print("""
      App Store Connect can't create apps through its API, so fill in Apps › + › New App:
        Platforms         iOS, and macOS if you like (not tvOS or visionOS: they can't use alternative distribution)
        Name              \(appRecord.name)   (unique across App Store Connect; if taken, try "\(appRecord.name) Torrent")
        Primary language  \(appRecord.language)
        Bundle ID         \(bundleID)
        SKU               \(appRecord.sku)
        User access       Full Access
    """)
    // Only wait when someone is there to fill in the form.
    guard isatty(STDIN_FILENO) != 0 else { throw APIError(status: 0, detail: "no app record for \(bundleID) yet; create it, then run `make setup-app` again") }
    try run(["open", "https://appstoreconnect.apple.com/apps"], allowFailure: true)
    print("  waiting for it to appear (checks every 15 s, up to 20 min)…")
    for _ in 0..<80 {
        try await Task.sleep(for: .seconds(15))
        if let app = items(try await api("GET", lookup)).first {
            print("  ✓ \"\(attribute(app, "name") as? String ?? "?")\" (\(app["id"] as? String ?? "?"))")
            return
        }
    }
    throw APIError(status: 0, detail: "still no app record for \(bundleID); run `make setup-app` again once it is created")
}

if command == "setup" {
    do { try await setUpApp() } catch { fail("\(error)") }
    if !failures.isEmpty {
        print("\nFinished with \(failures.count) problem(s):")
        failures.forEach { print("  • \($0)") }
        exit(1)
    }
    print("""
    ✓ Skein is set up in App Store Connect. Next:
      1. `make altstore-register`, then add the token under Users and Access › Integrations › Marketplace and select Skein.
      2. `make listing` to fill in the metadata notarization needs.
    """)
    exit(0)
}

// MARK: - App

print("→ Looking up \(bundleID)…")
let apps = items(try await api("GET", "/v1/apps?filter%5BbundleId%5D=\(bundleID)"))
guard let app = apps.first, let appID = app["id"] as? String else {
    fail("No app with bundle ID \(bundleID) in App Store Connect. Create the app record first (Apps › +).")
}
print("  app \(appID): \"\(attribute(app, "name") as? String ?? "?")\"")

// MARK: - Versions

/// States in which a version's metadata and build can still change.
let editableStates: Set<String> = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"]

func state(_ version: JSON) -> String {
    (attribute(version, "appVersionState") as? String) ?? (attribute(version, "appStoreState") as? String) ?? "?"
}

func iosVersions() async throws -> [JSON] {
    // Newest first. This endpoint rejects `sort`, so order by creation date here (ISO 8601 sorts as text).
    try await all("/v1/apps/\(appID)/appStoreVersions?filter%5Bplatform%5D=IOS&limit=200").data
        .sorted { (attribute($0, "createdDate") as? String ?? "") > (attribute($1, "createdDate") as? String ?? "") }
}

/// The version being prepared, created when there is none. Always marked NOTARIZATION so it is never sent to App Review.
@MainActor
func editableVersion(versionString: String?) async throws -> String {
    let versions = try await iosVersions()
    if let version = versions.first(where: { editableStates.contains(state($0)) }), let id = version["id"] as? String {
        var attributes: JSON = ["reviewType": "NOTARIZATION"]
        let current = attribute(version, "versionString") as? String ?? "?"
        if let versionString, versionString != current { attributes["versionString"] = versionString }
        try await api("PATCH", "/v1/appStoreVersions/\(id)", ["data": ["type": "appStoreVersions", "id": id, "attributes": attributes]])
        print("  = editing version \(versionString ?? current) (notarization)")
        return id
    }
    guard let versionString else { throw APIError(status: 0, detail: "no editable version; upload a build first (`make upload`), then run `make notarize`") }
    let id = createdID(try await api("POST", "/v1/appStoreVersions", [
        "data": ["type": "appStoreVersions",
                 "attributes": ["platform": "IOS", "versionString": versionString, "reviewType": "NOTARIZATION"],
                 "relationships": ["app": resource("apps", id: appID)]],
    ]))
    print("  + created version \(versionString) (notarization)")
    return id
}

// MARK: - Store listing

@MainActor
func setUpListing() async throws {
    try requireSettings(["DEVELOPER_NAME", "SUPPORT_URL", "PRIVACY_POLICY_URL"])
    print("→ App information…")
    let appInfos = try await all("/v1/apps/\(appID)/appInfos?limit=50").data
    // The editable app info is the one not yet live.
    let editable = appInfos.first { !["READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_INFO"].contains((attribute($0, "state") as? String) ?? (attribute($0, "appStoreState") as? String) ?? "") } ?? appInfos.first
    guard let appInfo = editable, let appInfoID = appInfo["id"] as? String else { throw APIError(status: 0, detail: "no app info found") }

    await attempt("category") {
        try await api("PATCH", "/v1/appInfos/\(appInfoID)", [
            "data": ["type": "appInfos", "id": appInfoID, "relationships": ["primaryCategory": resource("appCategories", id: listing.category)]],
        ])
        print("  ✓ category: Utilities")
    }

    await attempt("subtitle and privacy policy") {
        let localizations = try await all("/v1/appInfos/\(appInfoID)/appInfoLocalizations?limit=50").data
        guard let english = localizations.first(where: { attribute($0, "locale") as? String == locale }), let id = english["id"] as? String else {
            throw APIError(status: 0, detail: "no \(locale) app info localization (is en-US the primary language?)")
        }
        try await api("PATCH", "/v1/appInfoLocalizations/\(id)", [
            "data": ["type": "appInfoLocalizations", "id": id,
                     "attributes": ["subtitle": listing.subtitle, "privacyPolicyUrl": privacyPolicyURL]],
        ])
        print("  ✓ subtitle and privacy policy URL")
    }

    await attempt("content rights") {
        try await api("PATCH", "/v1/apps/\(appID)", [
            "data": ["type": "apps", "id": appID, "attributes": ["contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"]],
        ])
        print("  ✓ content rights: no third-party content")
    }

    await attempt("age rating") {
        let declaration = try await api("GET", "/v1/appInfos/\(appInfoID)/ageRatingDeclaration")
        guard let data = declaration["data"] as? JSON, let id = data["id"] as? String else { throw APIError(status: 0, detail: "no age rating declaration") }
        let asked = Set((data["attributes"] as? JSON ?? [:]).keys)
        let answers = ageRating.filter { asked.contains($0.key) }
        try await api("PATCH", "/v1/ageRatingDeclarations/\(id)", [
            "data": ["type": "ageRatingDeclarations", "id": id, "attributes": answers],
        ])
        print("  ✓ age rating (\(answers.count) answers)")
        let unanswered = asked.subtracting(ageRating.keys).filter { !["kidsAgeBand", "seventeenPlus", "koreaAgeRatingOverride", "ageRatingOverride", "ageRatingOverrideV2", "developerAgeRatingInfoUrl", "gracRatingClassificationNumber"].contains($0) }
        if !unanswered.isEmpty { print("    ! please review in App Store Connect: \(unanswered.sorted().joined(separator: ", "))") }
    }

    print("→ Version…")
    // Without a build yet, a new version starts at 1.0; `notarize` renames it to match the uploaded build.
    let existing = try await iosVersions().first(where: { editableStates.contains(state($0)) })
    let versionID = try await editableVersion(versionString: existing == nil ? "1.0" : nil)

    await attempt("copyright and release") {
        try await api("PATCH", "/v1/appStoreVersions/\(versionID)", [
            "data": ["type": "appStoreVersions", "id": versionID,
                     "attributes": ["copyright": listing.copyright, "releaseType": "AFTER_APPROVAL"]],
        ])
        print("  ✓ copyright; released as soon as it is notarized")
    }

    await attempt("description, keywords and URLs") {
        let localizations = try await all("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations?limit=50").data
        let attributes: JSON = [
            "description": listing.description, "keywords": listing.keywords, "promotionalText": listing.promotionalText,
            "supportUrl": supportURL,
        ]
        if let english = localizations.first(where: { attribute($0, "locale") as? String == locale }), let id = english["id"] as? String {
            try await api("PATCH", "/v1/appStoreVersionLocalizations/\(id)", [
                "data": ["type": "appStoreVersionLocalizations", "id": id, "attributes": attributes],
            ])
        } else {
            var create = attributes
            create["locale"] = locale
            try await api("POST", "/v1/appStoreVersionLocalizations", [
                "data": ["type": "appStoreVersionLocalizations", "attributes": create,
                         "relationships": ["appStoreVersion": resource("appStoreVersions", id: versionID)]],
            ])
        }
        print("  ✓ description, keywords, promotional text and support URL")
    }

    await attempt("review information") {
        let phone = setting("REVIEW_PHONE")
        guard !phone.isEmpty else {
            print("  ! skipped review contact: set REVIEW_PHONE in Local.env and run again")
            return
        }
        let attributes: JSON = [
            "contactFirstName": setting("REVIEW_FIRST_NAME"), "contactLastName": setting("REVIEW_LAST_NAME"),
            "contactEmail": setting("REVIEW_EMAIL"), "contactPhone": phone,
            "demoAccountRequired": false, "notes": listing.reviewNotes,
        ]
        let current = try? await api("GET", "/v1/appStoreVersions/\(versionID)/appStoreReviewDetail")
        if let detail = current?["data"] as? JSON, let id = detail["id"] as? String {
            try await api("PATCH", "/v1/appStoreReviewDetails/\(id)", ["data": ["type": "appStoreReviewDetails", "id": id, "attributes": attributes]])
        } else {
            try await api("POST", "/v1/appStoreReviewDetails", [
                "data": ["type": "appStoreReviewDetails", "attributes": attributes,
                         "relationships": ["appStoreVersion": resource("appStoreVersions", id: versionID)]],
            ])
        }
        print("  ✓ review contact and notes")
    }
}

// MARK: - Screenshots

func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Replaces the version's screenshots with the captured ones, leaving a slot alone when it already matches.
@MainActor
func uploadScreenshots() async throws {
    print("→ Version…")
    let versionID = try await editableVersion(versionString: nil)
    let localizations = try await all("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations?limit=50").data
    guard let english = localizations.first(where: { attribute($0, "locale") as? String == locale }), let localizationID = english["id"] as? String else {
        throw APIError(status: 0, detail: "no \(locale) version localization; run `make listing` first")
    }
    let sets = try await all("/v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets?limit=50").data

    for (folder, displayType) in screenshotSets {
        let files = screenshotFiles(folder)
        guard !files.isEmpty else {
            failures.append("\(folder): no screenshots in \(screenshotsDir.relativePath)/\(folder) (run `make screenshots`)")
            print("  ✗ \(folder): nothing to upload")
            continue
        }
        await attempt("\(folder) screenshots") {
            print("→ \(displayType) (\(files.count) from \(screenshotsDir.relativePath)/\(folder))…")
            let setID: String
            if let existing = sets.first(where: { attribute($0, "screenshotDisplayType") as? String == displayType }), let id = existing["id"] as? String {
                setID = id
            } else {
                setID = createdID(try await api("POST", "/v1/appScreenshotSets", [
                    "data": ["type": "appScreenshotSets", "attributes": ["screenshotDisplayType": displayType],
                             "relationships": ["appStoreVersionLocalization": resource("appStoreVersionLocalizations", id: localizationID)]],
                ]))
            }
            let current = try await all("/v1/appScreenshotSets/\(setID)/appScreenshots?limit=50").data
            let wanted = try files.map { md5(try Data(contentsOf: $0)) }
            if current.compactMap({ attribute($0, "sourceFileChecksum") as? String }) == wanted {
                print("  = unchanged")
                return
            }
            for screenshot in current {
                if let id = screenshot["id"] as? String { try await api("DELETE", "/v1/appScreenshots/\(id)") }
            }
            // Uploaded in file order, which is the order the listing shows.
            for (file, checksum) in zip(files, wanted) {
                let data = try Data(contentsOf: file)
                let reserved = try await api("POST", "/v1/appScreenshots", [
                    "data": ["type": "appScreenshots", "attributes": ["fileName": file.lastPathComponent, "fileSize": data.count],
                             "relationships": ["appScreenshotSet": resource("appScreenshotSets", id: setID)]],
                ])
                guard let asset = reserved["data"] as? JSON, let id = asset["id"] as? String else { throw APIError(status: 0, detail: "no upload reservation for \(file.lastPathComponent)") }
                try await putParts(data, operations: attribute(asset, "uploadOperations") as? [JSON] ?? [], name: file.lastPathComponent)
                try await api("PATCH", "/v1/appScreenshots/\(id)", [
                    "data": ["type": "appScreenshots", "id": id, "attributes": ["uploaded": true, "sourceFileChecksum": checksum]],
                ])
                print("  + \(file.lastPathComponent)")
            }
        }
    }
}

// MARK: - Export compliance

/// Finds a declaration with these answers that still counts, newest first.
func usableDeclaration() async throws -> JSON? {
    // The documented /v1/apps/{id}/appEncryptionDeclarations is rejected by the live API; the filtered list works.
    let declarations = try await all("/v1/appEncryptionDeclarations?filter%5Bapp%5D=\(appID)&limit=200").data
        .sorted { (attribute($0, "createdDate") as? String ?? "") > (attribute($1, "createdDate") as? String ?? "") }
    return declarations.first { declaration in
        ["CREATED", "IN_REVIEW", "APPROVED"].contains(attribute(declaration, "appEncryptionDeclarationState") as? String ?? "")
            && attribute(declaration, "containsProprietaryCryptography") as? Bool == encryption.proprietary
            && attribute(declaration, "containsThirdPartyCryptography") as? Bool == encryption.thirdParty
            && attribute(declaration, "availableOnFrenchStore") as? Bool == encryption.france
    }
}

/// Files the export compliance answers (and the French declaration) once, for every build to reuse.
@MainActor
func setUpEncryption() async throws {
    print("→ Encryption declaration…")
    guard needsDeclaration else {
        print("  = none needed: standard encryption, not distributed in France, so no export documentation is due")
        print("    builds answer ITSAppUsesNonExemptEncryption = NO (Project.swift); `make notarize` answers older builds the same way")
        return
    }
    var declaration = try await usableDeclaration()
    if declaration == nil {
        let document = setting("ENCRYPTION_FRANCE_DOCUMENT")
        let documentURL = URL(fileURLWithPath: (document as NSString).expandingTildeInPath)
        if encryption.france {
            guard !document.isEmpty, FileManager.default.fileExists(atPath: documentURL.path) else {
                throw APIError(status: 0, detail: "set ENCRYPTION_FRANCE_DOCUMENT in Local.env to the French encryption declaration (ANSSI) you received")
            }
        }
        let created = try await api("POST", "/v1/appEncryptionDeclarations", [
            "data": ["type": "appEncryptionDeclarations",
                     "attributes": ["appDescription": encryption.description,
                                    "containsProprietaryCryptography": encryption.proprietary,
                                    "containsThirdPartyCryptography": encryption.thirdParty,
                                    "availableOnFrenchStore": encryption.france],
                     "relationships": ["app": resource("apps", id: appID)]],
        ])
        declaration = created["data"] as? JSON
        print("  + declaration (standard algorithms, no proprietary cryptography, available in France: \(encryption.france ? "yes" : "no"))")
        if encryption.france, let id = declaration?["id"] as? String {
            let data = try Data(contentsOf: documentURL)
            let reserved = try await api("POST", "/v1/appEncryptionDeclarationDocuments", [
                "data": ["type": "appEncryptionDeclarationDocuments",
                         "attributes": ["fileName": documentURL.lastPathComponent, "fileSize": data.count],
                         "relationships": ["appEncryptionDeclaration": resource("appEncryptionDeclarations", id: id)]],
            ])
            guard let asset = reserved["data"] as? JSON, let assetID = asset["id"] as? String else { throw APIError(status: 0, detail: "no upload reservation for the French declaration") }
            try await putParts(data, operations: attribute(asset, "uploadOperations") as? [JSON] ?? [], name: documentURL.lastPathComponent)
            try await api("PATCH", "/v1/appEncryptionDeclarationDocuments/\(assetID)", [
                "data": ["type": "appEncryptionDeclarationDocuments", "id": assetID, "attributes": ["uploaded": true, "sourceFileChecksum": md5(data)]],
            ])
            print("  + French declaration \(documentURL.lastPathComponent)")
        }
    }
    guard let declaration else { throw APIError(status: 0, detail: "no declaration") }
    let state = attribute(declaration, "appEncryptionDeclarationState") as? String ?? "?"
    print("  state \(state)")
    if let code = attribute(declaration, "codeValue") as? String, !code.isEmpty, state == "APPROVED" {
        if setting("TUIST_EXPORT_COMPLIANCE_CODE") == code {
            print("  = builds carry code \(code), so App Store Connect no longer asks")
        } else {
            print("  ! set TUIST_EXPORT_COMPLIANCE_CODE=\(code) in Local.env, so every build answers for itself (then `make upload`)")
        }
    }
}

/// Answers export compliance for a build from the filed declaration, so `notarize` needs no clicks.
@MainActor
func answerExportCompliance(buildID: String, buildNumber: String) async throws {
    guard needsDeclaration else {
        // Same answer the Info.plist key gives; only builds made before it was added get here.
        try await api("PATCH", "/v1/builds/\(buildID)", ["data": ["type": "builds", "id": buildID, "attributes": ["usesNonExemptEncryption": false]]])
        print("  ✓ export compliance: no documentation needed (standard encryption, not in France)")
        return
    }
    guard let declaration = try await usableDeclaration(), let id = declaration["id"] as? String else {
        throw APIError(status: 0, detail: "build \(buildNumber) has no export compliance answer; run `make encryption` first")
    }
    try await api("PATCH", "/v1/builds/\(buildID)/relationships/appEncryptionDeclaration", resource("appEncryptionDeclarations", id: id))
    try await api("PATCH", "/v1/builds/\(buildID)", ["data": ["type": "builds", "id": buildID, "attributes": ["usesNonExemptEncryption": true]]])
    let state = attribute(declaration, "appEncryptionDeclarationState") as? String ?? "?"
    print("  ✓ export compliance from the filed declaration (\(state.lowercased()))")
    // Only a French declaration waits on Apple's review; without one the answers are complete as filed.
    if encryption.france, state != "APPROVED" {
        throw APIError(status: 0, detail: "the encryption declaration is \(state.lowercased()); Apple has to approve it before build \(buildNumber) can be submitted. Run `make notarize` again once `make encryption` shows APPROVED")
    }
}

/// Sends bytes in the parts App Store Connect asks for.
func putParts(_ data: Data, operations: [JSON], name: String) async throws {
    for op in operations {
        guard let urlString = op["url"] as? String, let url = URL(string: urlString) else { continue }
        let offset = op["offset"] as? Int ?? 0, length = op["length"] as? Int ?? data.count
        var put = URLRequest(url: url)
        put.httpMethod = op["method"] as? String ?? "PUT"
        for header in op["requestHeaders"] as? [JSON] ?? [] {
            if let name = header["name"] as? String, let value = header["value"] as? String { put.setValue(value, forHTTPHeaderField: name) }
        }
        let (_, response) = try await URLSession.shared.upload(for: put, from: data.subdata(in: offset..<(offset + length)))
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw APIError(status: 0, detail: "uploading \(name) failed") }
    }
}

// MARK: - TestFlight (internal)

/// Waits for the newest upload to finish processing and returns it with its marketing version.
@MainActor
func latestProcessedBuild() async throws -> (build: JSON, version: String) {
    for poll in 0..<60 {
        // Newest upload first; wait while App Store Connect is still processing it.
        let json = try await api("GET", "/v1/builds?filter%5Bapp%5D=\(appID)&sort=-uploadedDate&limit=1&include=preReleaseVersion")
        // A fresh upload takes a few minutes to be listed at all, so an empty list is waited on like processing.
        guard let latest = items(json).first else {
            if poll == 0 { print("  no build listed yet; waiting in case one was just uploaded (checks every 30 s, up to 30 min)…") }
            try await Task.sleep(for: .seconds(30))
            continue
        }
        let processing = attribute(latest, "processingState") as? String ?? "?"
        if processing == "VALID" {
            let included = json["included"] as? [JSON] ?? []
            let version = included.first { $0["type"] as? String == "preReleaseVersions" && $0["id"] as? String == relatedID(latest, "preReleaseVersion") }
                .flatMap { attribute($0, "version") as? String } ?? "?"
            return (latest, version)
        }
        if processing == "FAILED" || processing == "INVALID" { throw APIError(status: 0, detail: "build \(attribute(latest, "version") ?? "?") is \(processing) in App Store Connect") }
        if poll == 0 { print("  build \(attribute(latest, "version") ?? "?") is \(processing.lowercased()); waiting (checks every 30 s, up to 30 min)…") }
        try await Task.sleep(for: .seconds(30))
    }
    throw APIError(status: 0, detail: "no processed build after 30 minutes; check the upload succeeded, then run again")
}

/// An internal group that gets every build, and the newest build's notes. Internal testing needs no review,
/// so it works from any country; testers are App Store Connect users added to the group.
@MainActor
func setUpBeta() async throws {
    print("→ Internal group…")
    let groups = try await all("/v1/apps/\(appID)/betaGroups?limit=200").data
    if groups.contains(where: { attribute($0, "name") as? String == beta.group }) {
        print("  = \"\(beta.group)\" exists")
    } else {
        try await api("POST", "/v1/betaGroups", [
            "data": ["type": "betaGroups",
                     // Internal testers get every new build automatically, so nothing is added per build.
                     "attributes": ["name": beta.group, "isInternalGroup": true, "hasAccessToAllBuilds": true],
                     "relationships": ["app": resource("apps", id: appID)]],
        ])
        print("  + \"\(beta.group)\" (internal, every build)")
    }

    print("→ Latest build…")
    let (build, version) = try await latestProcessedBuild()
    guard let buildID = build["id"] as? String else { throw APIError(status: 0, detail: "no build id") }
    let buildNumber = attribute(build, "version") as? String ?? "?"
    print("  \(version) (\(buildNumber)), expires \(attribute(build, "expirationDate") as? String ?? "?")")
    if attribute(build, "usesNonExemptEncryption") == nil || attribute(build, "usesNonExemptEncryption") is NSNull {
        try await answerExportCompliance(buildID: buildID, buildNumber: buildNumber)
    }
    await attempt("What to Test") {
        let localizations = try await all("/v1/builds/\(buildID)/betaBuildLocalizations?limit=50").data
        if let english = localizations.first(where: { attribute($0, "locale") as? String == locale }), let id = english["id"] as? String {
            try await api("PATCH", "/v1/betaBuildLocalizations/\(id)", ["data": ["type": "betaBuildLocalizations", "id": id, "attributes": ["whatsNew": beta.whatToTest]]])
        } else {
            try await api("POST", "/v1/betaBuildLocalizations", [
                "data": ["type": "betaBuildLocalizations", "attributes": ["locale": locale, "whatsNew": beta.whatToTest],
                         "relationships": ["build": resource("builds", id: buildID)]],
            ])
        }
        print("  ✓ \"What to Test\" notes")
    }
}

/// Whether TestFlight needs a fresh build: none is valid, or the newest expires within BETA_RENEW_DAYS (default 14).
/// Also picks the version to build: Project.swift's, unless App Store Connect already closed that version, in which
/// case the next patch after the highest version seen. Writes `needed` and `version` to GITHUB_OUTPUT for the workflow.
@MainActor
func checkBeta() async throws {
    let renewDays = Int(setting("BETA_RENEW_DAYS")) ?? 14
    let builds = items(try await api("GET", "/v1/builds?filter%5Bapp%5D=\(appID)&filter%5Bexpired%5D=false&filter%5BprocessingState%5D=VALID&sort=-uploadedDate&limit=1"))
    let formatter = ISO8601DateFormatter()
    var needed = true
    if let newest = builds.first, let expiry = (attribute(newest, "expirationDate") as? String).flatMap(formatter.date(from:)) {
        let days = Int(expiry.timeIntervalSinceNow / 86_400)
        needed = days <= renewDays
        print("  newest build \(attribute(newest, "version") ?? "?") expires in \(days) days (renewing at \(renewDays))")
    } else {
        print("  no unexpired build")
    }

    // A version whose review finished takes no more builds, so builds after it need a higher number.
    let project = fromManifest(#""MARKETING_VERSION":\s*"([^"]+)""#) ?? "1.0"
    let closedStates: Set<String> = ["PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION", "PROCESSING_FOR_DISTRIBUTION", "ACCEPTED"]
    let versions = try await iosVersions()
    let closed = versions.filter { closedStates.contains(state($0)) }.compactMap { attribute($0, "versionString") as? String }
    func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0] }
    func less(_ a: String, _ b: String) -> Bool { parts(a).lexicographicallyPrecedes(parts(b)) }
    var version = project
    if let highest = closed.max(by: less), !less(highest, project) {
        let p = parts(highest)
        version = "\(p[0]).\(p[1]).\(p[2] + 1)"
        print("  \(highest) is closed for new builds, so building \(version)")
    }
    print(needed ? "  → a new build is needed (version \(version))" : "  = no new build needed")
    if let output = ProcessInfo.processInfo.environment["GITHUB_OUTPUT"], let handle = FileHandle(forWritingAtPath: output) {
        handle.seekToEndOfFile()
        handle.write(Data("needed=\(needed)\nversion=\(version)\n".utf8))
        try handle.close()
    }
}

// MARK: - Notarization

@MainActor
func submitForNotarization() async throws {
    print("→ Latest build…")
    var build: JSON?, included: [JSON] = []
    for poll in 0..<60 {
        // Newest upload first; wait while App Store Connect is still processing it.
        let json = try await api("GET", "/v1/builds?filter%5Bapp%5D=\(appID)&sort=-uploadedDate&limit=1&include=preReleaseVersion")
        // A fresh upload takes a few minutes to be listed at all, so an empty list is waited on like processing.
        guard let latest = items(json).first else {
            if poll == 0 { print("  no build listed yet; waiting in case one was just uploaded (checks every 30 s, up to 30 min)…") }
            try await Task.sleep(for: .seconds(30))
            continue
        }
        let processing = attribute(latest, "processingState") as? String ?? "?"
        if processing == "VALID" { build = latest; included = json["included"] as? [JSON] ?? []; break }
        if processing == "FAILED" || processing == "INVALID" { throw APIError(status: 0, detail: "build \(attribute(latest, "version") ?? "?") is \(processing) in App Store Connect") }
        if poll == 0 { print("  build \(attribute(latest, "version") ?? "?") is \(processing.lowercased()); waiting (checks every 30 s, up to 30 min)…") }
        try await Task.sleep(for: .seconds(30))
    }
    guard let build, let buildID = build["id"] as? String else { throw APIError(status: 0, detail: "no processed build after 30 minutes; check `make upload` succeeded, then run `make notarize` again") }
    let buildNumber = attribute(build, "version") as? String ?? "?"
    let marketing = included.first { $0["type"] as? String == "preReleaseVersions" && $0["id"] as? String == relatedID(build, "preReleaseVersion") }
        .flatMap { attribute($0, "version") as? String }
    guard let marketing else { throw APIError(status: 0, detail: "couldn't read build \(buildNumber)'s version number") }
    print("  build \(marketing) (\(buildNumber)) is ready")

    // Builds carrying TUIST_EXPORT_COMPLIANCE_CODE arrive answered; others take the declaration `make encryption` filed.
    if attribute(build, "usesNonExemptEncryption") == nil || attribute(build, "usesNonExemptEncryption") is NSNull {
        try await answerExportCompliance(buildID: buildID, buildNumber: buildNumber)
    }

    print("→ Version \(marketing)…")
    let versionID = try await editableVersion(versionString: marketing)
    try await api("PATCH", "/v1/appStoreVersions/\(versionID)/relationships/build", resource("builds", id: buildID))
    print("  ✓ build \(buildNumber) attached")

    print("→ Submission…")
    let open = try await all("/v1/reviewSubmissions?filter%5Bapp%5D=\(appID)&filter%5Bplatform%5D=IOS&filter%5Bstate%5D=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES&limit=50").data
    if let busy = open.first(where: { ["WAITING_FOR_REVIEW", "IN_REVIEW"].contains(attribute($0, "state") as? String ?? "") }) {
        print("  = already submitted: \(attribute(busy, "state") as? String ?? "?")")
        return
    }
    let submissionID: String
    if let ready = open.first(where: { attribute($0, "state") as? String == "READY_FOR_REVIEW" }), let id = ready["id"] as? String {
        submissionID = id
        print("  = reusing draft submission")
    } else {
        submissionID = createdID(try await api("POST", "/v1/reviewSubmissions", [
            "data": ["type": "reviewSubmissions", "attributes": ["platform": "IOS"], "relationships": ["app": resource("apps", id: appID)]],
        ]))
        print("  + created submission")
    }
    let current = try await all("/v1/reviewSubmissions/\(submissionID)/items?limit=50").data
    if !current.contains(where: { relatedID($0, "appStoreVersion") == versionID }) {
        try await api("POST", "/v1/reviewSubmissionItems", [
            "data": ["type": "reviewSubmissionItems", "relationships": [
                "reviewSubmission": resource("reviewSubmissions", id: submissionID),
                "appStoreVersion": resource("appStoreVersions", id: versionID),
            ]],
        ])
        print("  + version \(marketing) added")
    }
    try await api("PATCH", "/v1/reviewSubmissions/\(submissionID)", [
        "data": ["type": "reviewSubmissions", "id": submissionID, "attributes": ["submitted": true]],
    ])
    print("  ✓ submitted for notarization")
}

// MARK: - Status

/// The ADP for a version and its newest completed package version, if Apple has generated one.
func package(for versionID: String) async throws -> (id: String, version: JSON?)? {
    guard let adp = try? await api("GET", "/v1/appStoreVersions/\(versionID)/alternativeDistributionPackage"),
          let data = adp["data"] as? JSON, let id = data["id"] as? String else { return nil }
    let versions = try await all("/v1/alternativeDistributionPackages/\(id)/versions?filter%5Bstate%5D=COMPLETED&limit=50").data
    return (id, versions.first)
}

@MainActor
func showStatus() async throws {
    print("→ Versions…")
    for version in try await iosVersions().prefix(5) {
        let id = version["id"] as? String ?? ""
        let line = "  \(attribute(version, "versionString") as? String ?? "?")  \(state(version))  review \(attribute(version, "reviewType") as? String ?? "?")"
        if let adp = try await package(for: id) {
            print(line + "  ADP \(adp.id)" + (adp.version == nil ? " (no completed package yet)" : " ✓"))
        } else {
            print(line)
        }
    }
    print("→ Submissions…")
    for submission in try await all("/v1/reviewSubmissions?filter%5Bapp%5D=\(appID)&filter%5Bplatform%5D=IOS&limit=5").data.prefix(5) {
        print("  \(attribute(submission, "submittedDate") as? String ?? "not submitted")  \(attribute(submission, "state") as? String ?? "?")")
    }
}

// MARK: - Release (AltStore PAL via GitHub Releases)

/// Runs a command, failing with its output when it exits non-zero.
@discardableResult
func run(_ arguments: [String], allowFailure: Bool = false) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard allowFailure || process.terminationStatus == 0 else {
        throw APIError(status: 0, detail: "`\(arguments.joined(separator: " "))` failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return (process.terminationStatus, output)
}

/// The public repository the release goes to: GITHUB_REPOSITORY in Actions, otherwise this checkout's own.
func releaseRepository() throws -> String {
    if !setting("GITHUB_REPOSITORY").isEmpty { return setting("GITHUB_REPOSITORY") }
    return try run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]).output
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The newest version whose alternative distribution package Apple has built, and the release tag it maps to.
func newestNotarized() async throws -> (marketing: String, buildNumber: String, minOS: String, adpID: String, tag: String)? {
    for version in try await iosVersions() {
        guard let versionID = version["id"] as? String, let adp = try await package(for: versionID), adp.version != nil else { continue }
        let build = (try await api("GET", "/v1/appStoreVersions/\(versionID)/build"))["data"] as? JSON ?? [:]
        let marketing = attribute(version, "versionString") as? String ?? "?"
        let buildNumber = attribute(build, "version") as? String ?? "?"
        return (marketing, buildNumber, attribute(build, "minOsVersion") as? String ?? "26.0", adp.id, "v\(marketing)-\(buildNumber)")
    }
    return nil
}

/// Whether a release can be published right now, without waiting: the newest notarized version has no GitHub release
/// yet and AltStore has finished processing its package. Writes `ready` to GITHUB_OUTPUT, so a scheduled workflow
/// only runs the release job when there is something to publish.
@MainActor
func checkRelease() async throws {
    var ready = false
    defer {
        if let output = ProcessInfo.processInfo.environment["GITHUB_OUTPUT"], let handle = FileHandle(forWritingAtPath: output) {
            handle.seekToEndOfFile()
            handle.write(Data("ready=\(ready)\n".utf8))
            try? handle.close()
        }
    }
    print("→ Notarized version…")
    guard let notarized = try await newestNotarized() else {
        print("  = nothing notarized yet")
        return
    }
    print("  \(notarized.marketing) (\(notarized.buildNumber)), ADP \(notarized.adpID)")

    let repo = try releaseRepository()
    let assets = (try? JSONSerialization.jsonObject(with: Data(try run(["gh", "release", "view", notarized.tag, "--repo", repo, "--json", "assets"], allowFailure: true).output.utf8))) as? JSON
    if let existing = assets?["assets"] as? [JSON], existing.contains(where: { $0["name"] as? String == "manifest.json" }) {
        print("  = release \(notarized.tag) already published")
        return
    }

    print("→ AltStore…")
    let (status, data) = try await request("GET", URL(string: "https://api.altstore.io/adps/\(notarized.adpID)")!)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
    if json["downloadURL"] is String {
        ready = true
        print("  ✓ processed; release \(notarized.tag) can be published")
    } else if status == 404 {
        // Usually AltStore hears about the ADP from Apple's notification; this asks for it directly.
        let (posted, body) = try await request("POST", URL(string: "https://api.altstore.io/adps")!, json: ["adpID": notarized.adpID])
        guard (200..<300).contains(posted) else { throw APIError(status: posted, detail: "AltStore didn't accept the ADP: \(String(decoding: body, as: UTF8.self))") }
        print("  + sent ADP to AltStore; checking again next time")
    } else {
        print("  = \(json["status"] as? String ?? "HTTP \(status)") since \(json["updated"] as? String ?? "?"); checking again next time")
    }
}

@MainActor
func publishRelease() async throws {
    // The source repeats the listing text, which names these.
    try requireSettings(["DEVELOPER_NAME", "PRIVACY_POLICY_URL"])
    let repo = try releaseRepository()
    // Raw files on the default branch: the source is committed, so its URL never changes.
    let raw = "https://raw.githubusercontent.com/\(repo)/main"

    print("→ Notarized version…")
    guard let notarized = try await newestNotarized() else {
        throw APIError(status: 0, detail: "no version has an alternative distribution package yet; check `make status` (it appears once notarization passes and the AltStore marketplace is connected)")
    }
    let (marketing, buildNumber, minOS, adpID, tag) = (notarized.marketing, notarized.buildNumber, notarized.minOS, notarized.adpID, notarized.tag)
    print("  \(marketing) (\(buildNumber)), iOS \(minOS)+, ADP \(adpID)")
    // The workflow's macOS job attaches its build to the same release, with the same version numbers.
    if let output = ProcessInfo.processInfo.environment["GITHUB_OUTPUT"], let handle = FileHandle(forWritingAtPath: output) {
        handle.seekToEndOfFile()
        handle.write(Data("tag=\(tag)\nversion=\(marketing)\nbuild=\(buildNumber)\n".utf8))
        try handle.close()
    }

    var assets = (try? JSONSerialization.jsonObject(with: Data(try run(["gh", "release", "view", tag, "--repo", repo, "--json", "assets"], allowFailure: true).output.utf8))) as? JSON
    if let existing = assets?["assets"] as? [JSON], existing.contains(where: { $0["name"] as? String == "manifest.json" }) {
        print("  = release \(tag) already exists")
    } else {
        print("→ AltStore…")
        let adpURL = URL(string: "https://api.altstore.io/adps/\(adpID)")!
        var downloadURL: URL?
        for poll in 0..<60 {
            let (status, data) = try await request("GET", adpURL)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
            if let link = json["downloadURL"] as? String, let url = URL(string: link) { downloadURL = url; break }
            if poll == 0 {
                if status == 404 {
                    // Usually AltStore hears about the ADP from Apple's notification; this asks for it directly.
                    let (posted, body) = try await request("POST", URL(string: "https://api.altstore.io/adps")!, json: ["adpID": adpID])
                    guard (200..<300).contains(posted) else { throw APIError(status: posted, detail: "AltStore didn't accept the ADP: \(String(decoding: body, as: UTF8.self))") }
                    print("  + sent ADP to AltStore")
                }
                print("  \(json["status"] as? String ?? "processing"); waiting (checks every 30 s, up to 30 min)…")
            }
            try await Task.sleep(for: .seconds(30))
        }
        guard let downloadURL else { throw APIError(status: 0, detail: "AltStore hasn't finished processing; run `make release` again later") }

        let fm = FileManager.default
        let destination = publishDir.appendingPathComponent(tag)
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let (file, _) = try await URLSession.shared.download(from: downloadURL)
        // ditto keeps every byte as it was; PAL checks each file against manifest.json.
        try run(["ditto", "-x", "-k", file.path, destination.path])
        // Some archives wrap everything in one folder.
        var root = destination
        if !fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path),
           let inner = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first(where: { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) {
            root = inner
        }
        // Every file at any depth: Apple puts the per-device builds in variant/<publicId>.ipa. Release assets are flat,
        // which AltStore allows for through assetURLs, keyed by file name without extension (manifest, signature, and
        // each variant's publicId). So folders are dropped, but names must stay unique.
        let files = (fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && !$0.lastPathComponent.hasPrefix(".") }
        guard files.contains(where: { $0.lastPathComponent == "manifest.json" }) else { throw APIError(status: 0, detail: "the ADP has no manifest.json") }
        let names = files.map(\.lastPathComponent)
        if let duplicate = names.first(where: { name in names.filter { $0 == name }.count > 1 }) {
            throw APIError(status: 0, detail: "two ADP files are both named \(duplicate), which a flat list of release assets can't hold")
        }
        print("  ✓ ADP in \(root.relativePath) (\(files.count) files: \(names.sorted().joined(separator: ", ")))")

        print("→ GitHub release \(tag)…")
        let notes = """
        Skein \(marketing) (build \(buildNumber)) for iOS \(minOS) and later, notarized for alternative distribution.

        **iPhone and iPad:** install through AltStore PAL by adding this source: \(raw)/\(sourceFile.relativePath)

        **Mac:** download `Skein-\(marketing)-\(buildNumber)-macOS.zip` below (signed with Developer ID and notarized by Apple), unzip it and move Skein to Applications. It is attached separately, shortly after this release appears.

        The other files are an Alternative Distribution Package; AltStore checks each one against `manifest.json`, so they are only useful through AltStore. Skein is licensed under [LICENSE.md](https://github.com/\(repo)/blob/\(tag)/LICENSE.md). It includes VLCKit, licensed under the GNU LGPL 2.1; its license and the exact source used are at \(vlcKitSource). Other components are listed in [THIRD-PARTY-NOTICES.md](https://github.com/\(repo)/blob/\(tag)/THIRD-PARTY-NOTICES.md).
        """
        if assets == nil {
            try run(["gh", "release", "create", tag, "--repo", repo, "--title", "Skein \(marketing) (\(buildNumber))", "--notes", notes] + files.map(\.path))
        } else {
            // A release left half-uploaded by an earlier run: fill in what is missing.
            try run(["gh", "release", "upload", tag, "--repo", repo, "--clobber"] + files.map(\.path))
        }
        assets = (try JSONSerialization.jsonObject(with: Data(try run(["gh", "release", "view", tag, "--repo", repo, "--json", "assets"]).output.utf8))) as? JSON
        print("  ✓ uploaded \(files.count) files")
    }

    // Asset URLs as GitHub reports them, keyed by file name minus extension as AltStore expects.
    let uploaded = assets?["assets"] as? [JSON] ?? []
    var assetURLs: [String: String] = [:]
    var size = 0
    for asset in uploaded {
        // The macOS job's zip shares the release but isn't part of the ADP.
        guard let name = asset["name"] as? String, let url = asset["url"] as? String, !name.hasSuffix("-macOS.zip") else { continue }
        assetURLs[(name as NSString).deletingPathExtension] = url
        size += asset["size"] as? Int ?? 0
    }
    guard let manifestURL = assetURLs["manifest"] else { throw APIError(status: 0, detail: "release \(tag) has no manifest.json asset") }

    print("→ Source…")
    var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: sourceFile))) as? JSON ?? [:]
    var appEntry = (json["apps"] as? [JSON])?.first ?? [:]
    var versions = (appEntry["versions"] as? [JSON] ?? []).filter { $0["buildVersion"] as? String != buildNumber }
    versions.insert([
        "version": marketing, "buildVersion": buildNumber,
        "date": ISO8601DateFormatter().string(from: Date()),
        "downloadURL": manifestURL, "assetURLs": assetURLs,
        "size": size, "minOSVersion": minOS,
    ], at: 0)
    // Newest first: AltStore offers the first entry the device can run.
    versions.sort { (Int($0["buildVersion"] as? String ?? "") ?? 0) > (Int($1["buildVersion"] as? String ?? "") ?? 0) }
    let icon = "\(raw)/\(appIcon.relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appIcon.relativePath)"
    appEntry.merge([
        "name": "Skein", "bundleIdentifier": bundleID, "marketplaceID": appID,
        "developerName": developerName, "subtitle": listing.subtitle,
        "localizedDescription": listing.description, "iconURL": icon,
        "tintColor": source.tintColor, "category": source.category,
        "appPermissions": ["entitlements": source.entitlements, "privacy": source.privacy],
        "versions": versions,
    ]) { _, new in new }
    json.merge([
        "name": source.name, "identifier": source.identifier, "website": "https://github.com/\(repo)",
        "iconURL": icon, "tintColor": source.tintColor, "apps": [appEntry],
    ]) { _, new in new }
    // Optional: AltStore shows it as a link on the source.
    if !setting("PATREON_URL").isEmpty { json["patreonURL"] = setting("PATREON_URL") }
    let encoded = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try FileManager.default.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded.write(to: sourceFile)
    print("  ✓ \(sourceFile.relativePath) lists \(versions.count) version(s); commit and push it to publish")
    print("    AltStore PAL source URL: \(raw)/\(sourceFile.relativePath)")
}

// MARK: - Run

do {
    switch command {
    case "listing": try await setUpListing()
    case "screenshots": try await uploadScreenshots()
    case "encryption": try await setUpEncryption()
    case "beta": try await setUpBeta()
    case "beta-check": try await checkBeta()
    case "notarize": try await submitForNotarization()
    case "status": try await showStatus()
    case "release-check": try await checkRelease()
    default: try await publishRelease()
    }
} catch {
    fail("\(error)")
}

if failures.isEmpty {
    switch command {
    case "listing":
        print("✓ Listing filled in. Next: `make screenshots` and `make screenshots-upload`. Still by hand: App Privacy (Data Not Collected).")
    case "beta":
        print("✓ TestFlight is set up. Add yourself once: TestFlight › Internal Testing › \"\(beta.group)\" › Testers › +, then install from the TestFlight app.")
    case "screenshots":
        print("✓ Screenshots are on the version. App Store Connect processes them for a minute or two before they show.")
    case "notarize":
        print("✓ Waiting for notarization. `make status` shows progress; once it passes, `make release`.")
    case "release":
        print("✓ Released. Users get it once \(sourceFile.relativePath) is pushed to main.")
    default:
        break
    }
} else {
    print("\nFinished with \(failures.count) problem(s):")
    failures.forEach { print("  • \($0)") }
    exit(1)
}
