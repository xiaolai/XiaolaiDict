// OCR accuracy bench — renders known text, reads it back with Vision under several configurations, and
// counts the letter-words that came back exactly. Ground truth is known by construction.
//
//     swiftc -O Tools/ocr-bench/bench.swift -o /tmp/ocr-bench && /tmp/ocr-bench      # -v per style, -save PNGs to /tmp/ocrbench
//
// What it does NOT measure, on purpose: the pointer, the picker and the tokeniser (a hover test through
// `ScreenTextRecogniser.reading` did that once and is recorded in dev-docs/reading-the-screen.md §13), and
// real screens — these are clean renders, and the failures this app has met were not reproduced by them.
// Configuration A mirrors `ScreenTextRecogniser.recognise`; change one when you change the other.

import AppKit
import CoreText
import Vision

// Ground-truth lines: terminal-ish and prose, with rare words, identifiers, run-together tokens and edge punctuation.
let lines: [String] = [
    "The apothecary reviewed the ledger, but sciolism remained and cacoethes was absent.",
    "let trimmed = text.trimmingCharacters(in: .whitespaces) // ResNet labels",
    "$ git commit -m \"added the first case\" && ls /Users/alice/github/example",
    "Nginx Nginxo runtogether wordsrunwild UPPERCASETEXT state-of-the-art e-mail don't",
    "The spike has this comment: WebKit's word breaks and NLTokenizer's disagree.",
    "func resolve(sense: Sense, entries: [DictionaryEntry]) async -> SenseResolution",
    "error: the report could not be serialised (rn vs m: modern modem, urn um)",
    "Serendipity is ephemeral; a ubiquitous, mellifluous, perspicacious rendition.",
    "hold. (hold) \"hold\" 'hold' hold, hold; hold: hold! hold? [hold] {hold}",
    "0 O o 1 l I | 5 S 8 B rn m cl d vv w -- == != -> => :: ... 100% $5 C++ C#",
]
let truth: [String] = lines.flatMap { $0.split(separator: " ").map(String.init) }
let wordTruth: [String] = truth.filter { $0.filter(\.isLetter).count >= 3 }

struct Style { let font: String; let size: CGFloat; let dark: Bool; let scale: CGFloat; var blur: Double = 0; var dim: Bool = false; var name: String { "\(font) \(Int(size))pt \(dark ? "dark" : "light") @\(Int(scale))x\(blur > 0 ? " blur\(blur)" : "")\(dim ? " dim" : "")" } }

func render(_ style: Style) -> CGImage {
    let w = Int(1100 * style.scale), lineH = style.size * 1.45
    let h = Int((CGFloat(lines.count) * lineH + 24) * style.scale)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bg = style.dark ? CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let fg = style.dim ? CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1) : style.dark ? CGColor(red: 0.83, green: 0.83, blue: 0.83, alpha: 1) : CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
    ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: style.scale, y: style.scale)
    ctx.setShouldAntialias(true); ctx.setShouldSmoothFonts(true); ctx.setAllowsFontSmoothing(true)
    let font = CTFontCreateWithName(style.font as CFString, style.size, nil)
    for (i, line) in lines.enumerated() {
        let attr = NSAttributedString(string: line, attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: fg)!])
        let l = CTLineCreateWithAttributedString(attr)
        let y = CGFloat(h) / style.scale - 12 - CGFloat(i + 1) * lineH + (lineH - style.size) / 2
        ctx.textPosition = CGPoint(x: 12, y: y)
        CTLineDraw(l, ctx)
    }
    var out = ctx.makeImage()!
    if style.blur > 0 {
        let ci = CIImage(cgImage: out)
        let f = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: ci, kCIInputRadiusKey: style.blur * style.scale])!
        out = CIContext().createCGImage(f.outputImage!.cropped(to: ci.extent), from: ci.extent)!
    }
    return out
}

func upscale(_ img: CGImage, by f: Int) -> CGImage {
    let w = img.width * f, h = img.height * f
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

struct Config {
    let name: String
    let apply: (VNRecognizeTextRequest) -> Void
    var up = 1

    /// The same request on an image enlarged `factor` times: derived, so a pair can differ only in the enlargement.
    func upscaled(by factor: Int, named name: String) -> Config { Config(name: name, apply: apply, up: factor) }
}

struct BenchError: Error, CustomStringConvertible { let description: String }

func read(_ img: CGImage, _ cfg: Config) throws -> [String] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    cfg.apply(req)
    let src = cfg.up > 1 ? upscale(img, by: cfg.up) : img
    // A failed request is not a miss: it stops the run, naming what failed, instead of lowering a total.
    try VNImageRequestHandler(cgImage: src).perform([req])
    // Production keeps the first candidate only.
    return (req.results ?? []).flatMap { observation in
        (observation.topCandidates(1).first?.string ?? "").split(separator: " ").map(String.init)
    }
}

func score(_ got: [String], against truth: [String]) -> (hit: Int, missed: [String]) {
    var pool: [String: Int] = [:]
    for t in got { pool[t, default: 0] += 1 }
    var hit = 0; var missed: [String] = []
    for t in truth { if let n = pool[t], n > 0 { pool[t] = n - 1; hit += 1 } else { missed.append(t) } }
    return (hit, missed)
}

let baselineA = Config(name: "A production (auto-lang, no correction)") { $0.usesLanguageCorrection = false; $0.automaticallyDetectsLanguage = true }
let baselineB = Config(name: "B en-US pinned, no correction") { $0.usesLanguageCorrection = false; $0.automaticallyDetectsLanguage = false; $0.recognitionLanguages = ["en-US"] }
let configs: [Config] = [
    baselineA,
    baselineB,
    Config(name: "C en-US+zh-Hans, no correction") { $0.usesLanguageCorrection = false; $0.automaticallyDetectsLanguage = false; $0.recognitionLanguages = ["en-US", "zh-Hans"] },
    Config(name: "D auto-lang, correction ON") { $0.usesLanguageCorrection = true; $0.automaticallyDetectsLanguage = true },
    baselineA.upscaled(by: 2, named: "E production + 2x upscale"),
    baselineB.upscaled(by: 2, named: "F en-US pinned + 2x upscale"),
]
let styles: [Style] = [
    Style(font: "Menlo-Regular", size: 11, dark: true, scale: 2),
    Style(font: "Menlo-Regular", size: 13, dark: true, scale: 2),
    Style(font: "SFMono-Regular", size: 12, dark: true, scale: 2),
    Style(font: "Menlo-Regular", size: 13, dark: false, scale: 2),
    Style(font: "Menlo-Regular", size: 12, dark: true, scale: 1),
    Style(font: "HelveticaNeue", size: 13, dark: false, scale: 2),
    Style(font: "Menlo-Regular", size: 12, dark: true, scale: 2, blur: 0.5),
    Style(font: "Menlo-Regular", size: 12, dark: true, scale: 2, blur: 0.8),
    Style(font: "Menlo-Regular", size: 12, dark: true, scale: 2, dim: true),
    Style(font: "Menlo-Regular", size: 12, dark: true, scale: 2, blur: 0.6, dim: true),
]
let verbose = CommandLine.arguments.contains("-v")
let saveDirectory = "/tmp/ocrbench"
print("word tokens (>=3 letters): \(wordTruth.count)")
var totals: [String: (Int, Int)] = [:]
var allMissed: [String: [String: Int]] = [:]
var per: [String: [String: Double]] = [:]
do {
    if CommandLine.arguments.contains("-save") {
        try FileManager.default.createDirectory(atPath: saveDirectory, withIntermediateDirectories: true)
    }
    for s in styles {
        let img = render(s)
        if CommandLine.arguments.contains("-save") {
            guard let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
                throw BenchError(description: "could not encode \(s.name) as PNG")
            }
            try png.write(to: URL(fileURLWithPath: "\(saveDirectory)/\(s.name.replacingOccurrences(of: " ", with: "_")).png"))
        }
        for c in configs {
            let got: [String]
            do { got = try read(img, c) } catch { throw BenchError(description: "Vision failed on \(s.name) | \(c.name): \(error)") }
            let (hit, missed) = score(got, against: wordTruth)
            totals[c.name, default: (0, 0)].0 += hit; totals[c.name, default: (0, 0)].1 += wordTruth.count
            for m in missed { allMissed[c.name, default: [:]][m, default: 0] += 1 }
            per[s.name, default: [:]][c.name] = Double(hit) / Double(wordTruth.count)
            if verbose { print("\(s.name) | \(c.name): \(hit)/\(wordTruth.count)") }
        }
    }
} catch {
    FileHandle.standardError.write(Data("ocr-bench failed: \(error)\n".utf8))
    exit(1)
}
print("\nTOTAL over \(styles.count) styles")
for c in configs { let t = totals[c.name]!; print(String(format: "%5.1f%%  %@", 100 * Double(t.0) / Double(t.1), c.name as NSString)) }
print("\nper style (A / B / D / E):")
for st in styles { let p = per[st.name]!; print(String(format: "%5.1f %5.1f %5.1f %5.1f  %@", 100*p[configs[0].name]!, 100*p[configs[1].name]!, 100*p[configs[3].name]!, 100*p[configs[4].name]!, st.name as NSString)) }
print("\nmost-missed under A:")
for (k, v) in (allMissed[configs[0].name] ?? [:]).sorted(by: { $0.value > $1.value }).prefix(25) { print("  \(v)x \(k)") }
