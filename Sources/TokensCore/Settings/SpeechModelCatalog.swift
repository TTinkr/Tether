

import Foundation

/// How a model is run on this Mac.
public enum SpeechModelRuntime: String, Sendable, Hashable, CaseIterable {
    /// Apple's on-device recognizer; nothing to download.
    case apple
    /// The bundled NeMo-Speech ggml worker (Parakeet family, including Orukeet).
    case nemoGGML
    /// The bundled transcribe-worker (transcribe.cpp, MIT): every downloadable model except Orukeet.
    case transcribeCpp
}

/// A number someone else measured and published, with where and when.
public struct PublishedSpeechStats: Sendable, Hashable {
    /// Average word error rate in percent (lower is better).
    public let wer: Double
    /// Real-time factor, inverse: seconds of audio transcribed per second (higher is faster).
    public let rtfx: Double?
    public let sourceName: String
    public let sourceURL: URL
    /// When the source was read, as YYYY-MM-DD.
    public let asOf: String
    /// Speed on a Mac: times faster than real time, as a third party publishes it (one runtime and
    /// chip for every row, so rows compare). The page's speed ticks use this, not the GPU `rtfx`.
    public let macRealtime: Double?
    public let macSourceName: String?
    public let macSourceURL: URL?
    /// Says what the number is when it is not this exact model's (Orukeet shows its base model's).
    public let note: String?

    public init(wer: Double, rtfx: Double?, sourceName: String, sourceURL: URL, asOf: String,
                macRealtime: Double? = nil, macSourceName: String? = nil, macSourceURL: URL? = nil,
                note: String? = nil) {
        self.wer = wer
        self.rtfx = rtfx
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.asOf = asOf
        self.macRealtime = macRealtime
        self.macSourceName = macSourceName
        self.macSourceURL = macSourceURL
        self.note = note
    }
}

/// Where a downloadable model's weights come from and how they are checked.
public struct SpeechModelDownload: Sendable, Hashable {
    public let url: URL
    public let sha256: String
    public let bytes: Int64
    public let fileName: String

    public init(url: URL, sha256: String, bytes: Int64, fileName: String) {
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
        self.fileName = fileName
    }
}

public struct SpeechModelEntry: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// "Apple", "Parakeet" or "Whisper".
    public let family: String
    public let runtime: SpeechModelRuntime
    /// nil when the maker does not publish it (Apple).
    public let parameters: Int?
    /// nil: built in, nothing to download.
    public let download: SpeechModelDownload?
    public let languages: String
    /// Code and weights licence, as the maker states it.
    public let licence: String
    public let published: PublishedSpeechStats?
    /// The published download size for a model whose download is not pinned yet.
    public let plannedDownloadBytes: Int64?

    /// Bytes to download: the pinned file's, else the planned published size; nil when built in.
    public var downloadBytes: Int64? { download?.bytes ?? plannedDownloadBytes }

    public init(id: String, name: String, family: String, runtime: SpeechModelRuntime, parameters: Int?,
                download: SpeechModelDownload?, languages: String, licence: String,
                published: PublishedSpeechStats?, plannedDownloadBytes: Int64? = nil) {
        self.id = id
        self.name = name
        self.family = family
        self.runtime = runtime
        self.parameters = parameters
        self.download = download
        self.languages = languages
        self.licence = licence
        self.published = published
        self.plannedDownloadBytes = plannedDownloadBytes
    }
}

/// Every model the Models tab lists, in display order. The engine layer adds a model here
/// only once its runtime is proven to load it; the page fills in published stats and sources.
public enum SpeechModelCatalog {
    public static let appleID = "apple"
    public static let orukeetID = "orukeet"

    /// Every model the page lists: the two that run today, then the rest of the planned ten.
    /// SpeechModelStore shows a row as coming soon until its family's runtime ships in the build.
    public static let all: [SpeechModelEntry] = current + upcoming

    static let current: [SpeechModelEntry] = [
        SpeechModelEntry(id: appleID, name: "Apple", family: "Apple", runtime: .apple, parameters: nil,
                         download: nil, languages: "Many", licence: "Built into macOS", published: nil),
        SpeechModelEntry(id: orukeetID, name: "Orukeet", family: "Parakeet", runtime: .nemoGGML,
                         parameters: 627_057_286,
                         download: SpeechModelDownload(
                            url: URL(string: "https://huggingface.co/oruk/orukeet/resolve/b59c13a733fce5cf193230d0fa317ee7f145a108/orukeet-v0.1.0-q8.gguf")!,
                            sha256: "93ce19c6d8244acbfea980eeaf970531d4f216171578ef8e041dcc2d070a45bd",
                            bytes: 714_456_704, fileName: "orukeet-v0.1.0-q8.gguf"),
                         languages: "25 European languages", licence: "CC-BY-SA-4.0 weights",
                         published: board(6.82, rtfx: 3332.74, mac: 204,
                                           note: "Leaderboard score of Parakeet TDT 0.6B v3, Orukeet's base model")),
    ]

    /*
    The rest of the planned ten (build 79): published stats and planned sizes only. Each runs on the bundled transcribe-worker
    from a pinned download; SpeechModelStore shows it as coming soon in a bundle without that worker.
    Every word error rate is the 2026-05-20 Open ASR Leaderboard 7-set average (results CSV
    revision f82da85) and every Mac speed is transcribe.cpp's
    published M4 Max Q8 figure; planned sizes are the published Q8 GGUF files. Parameter counts are
    the Hugging Face model API's safetensors totals (read 2026-10-15); Parakeet v2 publishes none
    there, so it keeps its model card's 0.6B. `runtime` is the planned path; the engine layer
    confirms it when it pins a row's download.
    */
    static let upcoming: [SpeechModelEntry] = [
        planned("parakeet-tdt-0.6b-v2", "Parakeet v2", family: "Parakeet", runtime: .transcribeCpp,
                parameters: 600_000_000, download: hf("parakeet-tdt-0.6b-v2-gguf", "382796e405a9fe37145938dccbabfb25e93e4286", "parakeet-tdt-0.6b-v2-Q8_0.gguf",
                    "f0d0e99cebb6d3b83f1f7069b82b5d3c2e39a54545b0da039cb4bafd9c4e5caa", 729_574_912), languages: "English", licence: "CC-BY-4.0",
                stats: board(6.44, rtfx: 3386.02, mac: 224)),
        planned("parakeet-tdt-0.6b-v3", "Parakeet v3", family: "Parakeet", runtime: .transcribeCpp,
                parameters: 627_057_286, download: hf("parakeet-tdt-0.6b-v3-gguf", "90f082450fcbacdb54e5900c44ef697c9ea59622", "parakeet-tdt-0.6b-v3-Q8_0.gguf",
                    "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7", 739_508_576), languages: "25 European languages", licence: "CC-BY-4.0",
                stats: board(6.82, rtfx: 3332.74, mac: 199)),
        planned("canary-1b-flash", "Canary 1B Flash", family: "Canary", runtime: .transcribeCpp,
                parameters: 811_049_984, download: hf("canary-1b-flash-gguf", "bd27c7ef67ca6347ae2f729a130658466beecc85", "canary-1b-flash-Q8_0.gguf",
                    "b23202a996d716c8d90c2c0da708ef72c9d340eda0e90c9e4a4436064de980ea", 1_048_131_424), languages: "English, German, Spanish, French",
                licence: "CC-BY-4.0", stats: board(6.81, rtfx: 1045.75, mac: 112)),
        planned("qwen3-asr-0.6b", "Qwen3 ASR", family: "Qwen", runtime: .transcribeCpp,
                parameters: 938_008_576, download: hf("Qwen3-ASR-0.6B-gguf", "28c66fba077f1359a42b52c55b618a24cdb6e0e7", "Qwen3-ASR-0.6B-Q8_0.gguf",
                    "f081b2d5e23bd669d92cc331d722a8a0681943b8e6f34b48996fd5c319b5acd8", 850_423_456), languages: "Many", licence: "Apache-2.0",
                stats: board(6.93, rtfx: 166.23, mac: 69)),
        planned("moonshine-streaming-medium", "Moonshine Medium", family: "Moonshine", runtime: .transcribeCpp,
                parameters: 265_898_112, download: hf("moonshine-streaming-medium-gguf", "0f99e956a9e63d591ddd7f2a20dfead255e96c68", "moonshine-streaming-medium-Q8_0.gguf",
                    "f7c9564249b508f6012927ec4f9e536087da53a7047f858ca9975bea5f75299e", 295_793_568), languages: "English", licence: "MIT",
                stats: board(7.18, rtfx: 448.15, mac: 61)),
        planned("whisper-large-v3-turbo", "Whisper Turbo", family: "Whisper", runtime: .transcribeCpp,
                parameters: 808_878_080, download: hf("whisper-large-v3-turbo-gguf", "ceea6c8a94a21ab85be244d311e874a39344dbf5", "whisper-large-v3-turbo-Q8_0.gguf",
                    "b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183", 886_381_760), languages: "Many", licence: "MIT",
                stats: board(8.44, rtfx: 200.19, mac: 44)),
        planned("whisper-small.en", "Whisper Small", family: "Whisper", runtime: .transcribeCpp,
                parameters: 241_734_144, download: hf("whisper-small.en-gguf", "465682f43898836b623801603ca6432a41275586", "whisper-small.en-Q8_0.gguf",
                    "9614e6b7fda2d26018e4f268aece8ca25a83296ea0b534169a585b740bfd71ef", 269_674_144), languages: "English", licence: "MIT",
                stats: board(9.24, rtfx: 268.91, mac: 92)),
        planned("whisper-base.en", "Whisper Base", family: "Whisper", runtime: .transcribeCpp,
                parameters: 72_593_408, download: hf("whisper-base.en-gguf", "f83d8d187299d4fc06e86a6de5084375ceac34bf", "whisper-base.en-Q8_0.gguf",
                    "3b46ca40bccbf7609c68d88a36d96077a04ca7c87f2060ede06f129fac3e7652", 84_886_208), languages: "English", licence: "MIT",
                stats: board(11.10, rtfx: 320.67, mac: 202)),
    ]

    /// The Open ASR Leaderboard (2026-05-20 results, 7 English sets) plus transcribe.cpp's M4 Max speed.
    static func board(_ wer: Double, rtfx: Double, mac: Double?, note: String? = nil) -> PublishedSpeechStats {
        PublishedSpeechStats(
            wer: wer, rtfx: rtfx, sourceName: "Open ASR Leaderboard",
            sourceURL: URL(string: "https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results")!,
            asOf: "2026-05-20", macRealtime: mac, macSourceName: mac == nil ? nil : "transcribe.cpp (M4 Max, Q8)",
            macSourceURL: mac == nil ? nil : URL(string: "https://github.com/handy-computer/transcribe.cpp")!,
            note: note)
    }

    static func planned(_ id: String, _ name: String, family: String, runtime: SpeechModelRuntime,
                        parameters: Int, download: SpeechModelDownload, languages: String, licence: String,
                        stats: PublishedSpeechStats) -> SpeechModelEntry {
        SpeechModelEntry(id: id, name: name, family: family, runtime: runtime, parameters: parameters,
                         download: download, languages: languages, licence: licence, published: stats)
    }

    /// A transcribe.cpp GGUF pinned to one Hugging Face commit, with its LFS sha256 and size
    /// (metadata checked 2026-10-15). Checked again after download.
    static func hf(_ repo: String, _ commit: String, _ file: String, _ sha256: String, _ bytes: Int64) -> SpeechModelDownload {
        SpeechModelDownload(url: URL(string: "https://huggingface.co/handy-computer/\(repo)/resolve/\(commit)/\(file)")!,
                            sha256: sha256, bytes: bytes, fileName: file)
    }

    public static func entry(_ id: String) -> SpeechModelEntry? { all.first { $0.id == id } }
}
