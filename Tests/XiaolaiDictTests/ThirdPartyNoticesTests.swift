import Foundation
import Testing
import XiaolaiDictTestSupport

/// **What the app is built from ships its licences with it.** The two XPC services statically link
/// thirteen packages, MIT and Apache-2.0 between them, and a static link leaves nothing in the
/// bundle to say they are there. `Tools/third-party-notices.sh` gathers each package's licence — and
/// the NOTICE that Apache-2.0 §4(d) asks for wherever one is shipped — into the file the bundle
/// carries and the About pane opens.
///
/// The generator is exercised rather than read: it is a build step, so nothing else would notice
/// the day it silently produced an empty file.
struct ThirdPartyNoticesTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Runs the generator with its working directory set to `root` — the script reads
    /// `.build/workspace-state.json` and `.build/checkouts` relative to it, which is what lets a
    /// fabricated root stand in for the real one.
    private func generate(in root: URL, into output: URL) throws -> (status: Int32, errors: String) {
        let script = repository.appending(path: "Tools/third-party-notices.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, output.path]
        process.currentDirectoryURL = root
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    /// Every package SwiftPM resolved is named, with its version and its licence under it.
    @Test func everyPackageTheBuildResolvesIsNamedWithItsLicence() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-notices")
        let output = scratch.appending("ThirdPartyNotices.txt")
        let run = try generate(in: repository, into: output)
        try #require(run.status == 0, "the generator failed: \(run.errors)")

        let notices = try String(contentsOf: output, encoding: .utf8)
        let resolved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: repository.appending(path: "Package.resolved")))
        let pins = try #require((resolved as? [String: Any])?["pins"] as? [[String: Any]])
        try #require(pins.count > 5, "found only \(pins.count) packages — the resolution is not what ships")

        for pin in pins {
            let identity = try #require(pin["identity"] as? String)
            let section = try #require(
                notices.range(of: "\n\(identity) "),
                "\(identity) is linked into the app and its licence is not in the notices")
            // A heading with nothing under it is the failure this exists to prevent: the licence
            // itself has to be there, and licence text says one of these things. Read as a fixed
            // window rather than up to the next section rule, because a licence is free to contain
            // whatever characters that rule is drawn with.
            let body = notices[section.upperBound...].prefix(2_000)
            #expect(body.contains("Copyright") || body.contains("Licensed under")
                    || body.contains("Apache License") || body.contains("Permission is hereby granted"),
                    "\(identity) is named but no licence text follows it")
        }
        #expect(notices.contains("NOTICE — swift-crypto"),
                "swift-crypto ships a NOTICE, and Apache-2.0 asks that it travel with the binary")
    }

    /// **A package whose checkout carries no licence stops the build by name.** A generator that
    /// skipped one would produce a file that looks complete and is not, which is the whole failure
    /// this file guards. The same fabricated root is then given a licence and must succeed — without
    /// that half, a script that refused *every* fabricated root would pass this test.
    @Test func aPackageWithNoLicenceStopsTheGenerator() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-notices")
        let checkout = scratch.appending(".build/checkouts/pretend-package")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let state: [String: Any] = ["object": ["dependencies": [[
            "packageRef": ["identity": "pretend-package", "location": "https://example.invalid/pretend"],
            "state": ["checkoutState": ["version": "1.0.0"]],
            "subpath": "pretend-package",
        ]]]]
        try JSONSerialization.data(withJSONObject: state)
            .write(to: scratch.appending(".build/workspace-state.json"))

        let output = scratch.appending("ThirdPartyNotices.txt")
        let refused = try generate(in: scratch.url, into: output)
        #expect(refused.status != 0, "a package with no licence was written into the notices anyway")
        #expect(refused.errors.contains("pretend-package"), "the refusal does not say which package: \(refused.errors)")
        #expect(!FileManager.default.fileExists(atPath: output.path),
                "a refused run left a notices file behind, which a build would then ship")

        try Data("Copyright 2026. Permission is hereby granted.".utf8)
            .write(to: checkout.appending(path: "LICENSE"))
        let accepted = try generate(in: scratch.url, into: output)
        #expect(accepted.status == 0, "a package with a licence was refused: \(accepted.errors)")
        #expect(try String(contentsOf: output, encoding: .utf8).contains("Permission is hereby granted"))
    }

    /// The notices are one of the bundle's inputs, and the bundle is rebuilt when a digest of its
    /// inputs changes — so a generator whose output reordered itself would re-sign the app for
    /// nothing, on every build.
    @Test func theSameDependenciesProduceTheSameBytes() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-notices")
        let first = scratch.appending("first.txt")
        let second = scratch.appending("second.txt")
        try #require(generate(in: repository, into: first).status == 0)
        try #require(generate(in: repository, into: second).status == 0)
        #expect(try Data(contentsOf: first) == Data(contentsOf: second))
    }
}
