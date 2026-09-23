import Foundation
import Testing
import XiaolaiDictTestSupport

/// **What `build-bundle.sh` refuses.** Its verification is the last thing between a broken bundle
/// and a reader — a service with the wrong executable name launches nothing, a resource bundle left
/// behind is a stale artefact signed with this project's Developer ID, and an ad-hoc signature keeps
/// none of the permission grants the app depends on. None of it had ever been exercised: the script
/// had no test at all, and a signed bundle that verifies proves only that today's bundle is right.
///
/// So each check is put in front of a bundle that breaks exactly one thing. The published bundle is
/// the positive control — unmodified, it must verify — and every mutation is made on a clone of it,
/// so what changed is one file.
@Suite(.serialized)
struct BundleVerificationTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let published = repository.appending(path: ".build/XiaolaiDict.app")
    /// Where `build-bundle.sh` finds the resource bundles the model service should carry. Handed to
    /// it so it does not start SwiftPM from inside `swift test`, where SwiftPM is already running.
    private static let products = repository.appending(path: ".build/out/Products/Release")
    /// **The published bundle, and only while it is the one these checks belong to.** A bundle
    /// built before a check existed fails on what that build did not know to produce — which says
    /// nothing about the check and would deadlock `make`, whose tests run before its build. The
    /// script answers this itself, from the digest of the inputs it recorded when it published.
    ///
    /// Asked once, because it shells out. Under `make test-swift` the signing identity is exported
    /// and the digest matches; under a bare `swift test` it is not, so these are skipped by name
    /// rather than failing on a difference that is about the environment.
    private static let bundleIsCurrent: Bool = {
        guard FileManager.default.fileExists(atPath: published.path),
              FileManager.default.fileExists(atPath: products.path)
        else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repository.appending(path: "Tools/build-bundle.sh").path, "current"]
        process.currentDirectoryURL = repository
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    private let scratches = Recorder<[TemporaryDirectory]>([])

    /// Runs `build-bundle.sh verify` over a bundle and returns what it said, refusals included.
    private func verify(_ bundle: URL) throws -> (status: Int32, said: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repository.appending(path: "Tools/build-bundle.sh").path,
                             "verify", bundle.path]
        process.currentDirectoryURL = Self.repository
        process.environment = ProcessInfo.processInfo.environment
            .merging(["XIAOLAIDICT_PRODUCTS": Self.products.path]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, said)
    }

    /// A clone of the published bundle. `cp -c` clones on APFS, so this costs no copy of the
    /// several hundred megabytes of linked MLX.
    private func clone() throws -> URL {
        let scratch = TemporaryDirectory(named: "xiaolaidict-bundle")
        scratches.withLock { $0.append(scratch) }
        let copy = scratch.appending("XiaolaiDict.app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-Rc", Self.published.path, copy.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "the published bundle could not be cloned")
        return copy
    }

    private func plist(_ path: String, _ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
        process.arguments = ["-c", command, path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "PlistBuddy refused: \(command)")
    }

    /// The control. Without it every refusal below could be the script refusing everything.
    @Test(.enabled(if: bundleIsCurrent, "the published bundle was not built from these inputs; run make"))
    func theBundleThatWasBuiltVerifies() throws {
        let run = try verify(Self.published)
        #expect(run.status == 0, "the published bundle does not verify:\n\(run.said)")
    }

    /// Each mutation breaks one thing, and the message names that thing — which is what says the
    /// refusal came from the check under test and not from the next one down.
    @Test(.enabled(if: bundleIsCurrent, "the published bundle was not built from these inputs; run make"), arguments: [
        ("the notices are missing", "Contents/Resources/ThirdPartyNotices.txt", "missing:"),
        // MLX's bundle is where the Metal shaders live, so its absence is caught by the check that
        // names them — a service without them loads and then dies at its first GPU op.
        ("the Metal shaders are missing",
         "Contents/XPCServices/XiaolaiDictModelService.xpc/Contents/Resources/mlx-swift_Cmlx.bundle",
         "default.metallib"),
        // And one the build produced that nothing else names: this is the check that reads the
        // model service's own build graph rather than a list kept by hand.
        ("a resource bundle the build produced is missing",
         "Contents/XPCServices/XiaolaiDictModelService.xpc/Contents/Resources/swift-transformers_Hub.bundle",
         "missing from the model service:"),
    ])
    func aBundleMissingSomethingIsRefused(_ name: String, path: String, says: String) throws {
        let copy = try clone()
        try FileManager.default.removeItem(at: copy.appending(path: path))
        let run = try verify(copy)
        #expect(run.status != 0, "\(name) and the bundle verified anyway")
        #expect(run.said.contains(says), "\(name): the refusal was \"\(run.said)\"")
    }

    /// A bundle the build did not produce, carried into the app and signed with it. This is the
    /// stale-cache case: `make clean` keeps SwiftPM's cache, so a dependency that has been removed
    /// leaves its bundle sitting in the products directory.
    @Test(.enabled(if: bundleIsCurrent, "the published bundle was not built from these inputs; run make"))
    func aResourceBundleTheBuildDidNotProduceIsRefused() throws {
        let copy = try clone()
        let stray = copy.appending(
            path: "Contents/XPCServices/XiaolaiDictModelService.xpc/Contents/Resources/long-gone_Thing.bundle")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let run = try verify(copy)
        #expect(run.status != 0, "a bundle this build never produced was accepted")
        #expect(run.said.contains("which this build did not produce"), "the refusal was \"\(run.said)\"")
    }

    /// The launch-critical keys. Each of these builds, signs and verifies as a signature — and then
    /// every lookup fails at runtime with nothing to say why.
    @Test(.enabled(if: bundleIsCurrent, "the published bundle was not built from these inputs; run make"), arguments: [
        ("the executable is named wrongly", "Set :CFBundleExecutable NotTheService",
         "declares CFBundleExecutable"),
        ("it is not declared an XPC service", "Set :CFBundlePackageType APPL",
         "is not declared as an XPC service"),
        ("it is not launched on demand", "Set :XPCService:ServiceType OnDemand",
         "does not declare XPCService:ServiceType Application"),
        ("the floor moved", "Set :LSMinimumSystemVersion 26.0",
         "declares a different LSMinimumSystemVersion"),
    ])
    func aServiceThatCouldNotLaunchIsRefused(_ name: String, command: String, says: String) throws {
        let copy = try clone()
        try plist(copy.appending(path: "Contents/XPCServices/XiaolaiDictModelService.xpc/Contents/Info.plist").path,
                  command)
        let run = try verify(copy)
        #expect(run.status != 0, "\(name) and the bundle verified anyway")
        #expect(run.said.contains(says), "\(name): the refusal was \"\(run.said)\"")
    }

    /// An ad-hoc signature verifies as a signature. It also keeps none of the permission grants
    /// macOS keys to a signing identity, so a reader would be asked for Accessibility again — and
    /// this is the check that says so rather than letting it ship.
    @Test(.enabled(if: bundleIsCurrent, "the published bundle was not built from these inputs; run make"))
    func anAdHocSignatureIsRefused() throws {
        let copy = try clone()
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--options", "runtime", "--sign", "-", copy.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0, "the clone could not be re-signed ad hoc")

        let run = try verify(copy)
        #expect(run.status != 0, "an ad-hoc signature was accepted")
        #expect(run.said.contains("team identifier") || run.said.contains("not by"),
                "the refusal was \"\(run.said)\"")
    }
}
