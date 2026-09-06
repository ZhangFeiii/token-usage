import Foundation

public protocol UsageCollecting: Sendable {
    func collect() async -> UsageCollectionReport
}

/// A pluggable local usage source. Implementations may live outside
/// `TokenBallCore`, which lets a future agent integrate without changing the
/// built-in Codex, OpenCode, or DeepSeek readers.
///
/// The provider is deliberately limited to normalized records. The collector
/// owns persistence, deduplication, and failure isolation for every source.
public protocol UsageSourceProvider: Sendable {
    /// Stable human-readable source identifier used in collection issues.
    var sourceID: String { get }

    /// Reads this source without mutating TokenBall's store.
    func collectRecords() async throws -> [UsageRecord]
}

/// Source-compatible spelling for clients that prefer the `Providing` form.
public typealias UsageSourceProviding = UsageSourceProvider

public struct UsageCollectionIssue: Equatable, Sendable {
    public let source: String
    public let message: String

    public init(source: String, message: String) {
        self.source = source
        self.message = message
    }
}

public struct UsageCollectionReport: Equatable, Sendable {
    public let discoveredRecordCount: Int
    public let importedRecordCount: Int
    public let issues: [UsageCollectionIssue]

    public init(
        discoveredRecordCount: Int,
        importedRecordCount: Int,
        issues: [UsageCollectionIssue]
    ) {
        self.discoveredRecordCount = discoveredRecordCount
        self.importedRecordCount = importedRecordCount
        self.issues = issues
    }
}

/// Imports TokenBall's self-owned local usage sources into its own SQLite
/// store. Every source is collected on every refresh and deduplicated through
/// stable record IDs, so the statistics no longer depend on any external
/// accounting database. Source failures are reported independently and never
/// thrown to the UI.
public actor LocalUsageCollector: UsageCollecting {
    public static var defaultCodexArchiveDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("archived_sessions", isDirectory: true)
    }

    /// Codex 8.x keeps active rollouts under `~/.codex/sessions/YYYY/MM/DD/`
    /// and stopped writing `archived_sessions`, so both locations are scanned.
    public static var defaultCodexSessionDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    public static var defaultOpenCodeDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db", isDirectory: false)
    }

    /// DeepSeek Harness stores CLI sessions and desktop sessions separately.
    public static var defaultDeepSeekHarnessSessionDirectoryURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".dsh", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true),
            home.appendingPathComponent(".dsh_desktop", isDirectory: true)
        ]
    }

    /// Canonical JSON files written here are imported on the next refresh.
    public static var defaultJSONImportDirectoryURL: URL {
        SQLiteUsageRepository.defaultDatabaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("imports", isDirectory: true)
    }

    /// Legacy record-ID prefix from the removed CC Switch statistics source.
    /// Kept as a data-level migration constant so records imported before the
    /// decoupling are purged instead of double counted.
    private static let legacyCCSwitchRecordIDPrefix = "cc-switch:"

    /// Keep enough history to fill the dashboard's 140-day activity window.
    /// The extra day includes boundary events when local calendar/timezone
    /// conversion moves a record across midnight.
    private static let codexWindowSeconds: TimeInterval = 141 * 86_400

    private let store: any UsageRecordStore
    private let codexArchiveDirectoryURL: URL
    private let codexSessionDirectoryURL: URL
    private let openCodeDatabaseURL: URL
    private let deepSeekHarnessSessionDirectoryURLs: [URL]
    private let jsonImportDirectoryURL: URL
    private let additionalSources: [any UsageSourceProvider]
    private let fileManager: FileManager
    private let zstdDecompressor: any ZstdDecompressing
    private let codexParser = CodexJSONLUsageParser()
    private let genericJSONParser = GenericJSONUsageParser()
    private let deepSeekHarnessParser = DeepSeekHarnessJSONLUsageParser()
    private var importedCodexFingerprints: [URL: FileFingerprint] = [:]
    private var importedJSONFingerprints: [URL: FileFingerprint] = [:]
    private var importedDeepSeekHarnessFingerprints: [URL: FileFingerprint] = [:]

    public init(
        store: any UsageRecordStore,
        codexArchiveDirectoryURL: URL = LocalUsageCollector.defaultCodexArchiveDirectoryURL,
        codexSessionDirectoryURL: URL = LocalUsageCollector.defaultCodexSessionDirectoryURL,
        openCodeDatabaseURL: URL = LocalUsageCollector.defaultOpenCodeDatabaseURL,
        deepSeekHarnessSessionDirectoryURLs: [URL] = LocalUsageCollector.defaultDeepSeekHarnessSessionDirectoryURLs,
        jsonImportDirectoryURL: URL = LocalUsageCollector.defaultJSONImportDirectoryURL,
        fileManager: FileManager = .default,
        zstdDecompressor: any ZstdDecompressing = ZstdCommandDecompressor(),
        additionalSources: [any UsageSourceProvider] = []
    ) {
        self.store = store
        self.codexArchiveDirectoryURL = codexArchiveDirectoryURL
        self.codexSessionDirectoryURL = codexSessionDirectoryURL
        self.openCodeDatabaseURL = openCodeDatabaseURL
        self.deepSeekHarnessSessionDirectoryURLs = deepSeekHarnessSessionDirectoryURLs
        self.jsonImportDirectoryURL = jsonImportDirectoryURL
        self.additionalSources = additionalSources
        self.fileManager = fileManager
        self.zstdDecompressor = zstdDecompressor
    }

    public func collect() async -> UsageCollectionReport {
        var records: [UsageRecord] = []
        var issues: [UsageCollectionIssue] = []
        var processedFingerprints: [URL: FileFingerprint] = [:]
        var processedJSONFingerprints: [URL: FileFingerprint] = [:]
        var processedDeepSeekHarnessFingerprints: [URL: FileFingerprint] = [:]

        // Migration: purge records imported from the removed CC Switch
        // statistics database. Idempotent, so it also self-heals databases
        // that were seeded before the decoupling.
        do {
            _ = try await store.removeRecords(
                withIDPrefixes: [Self.legacyCCSwitchRecordIDPrefix]
            )
        } catch {
            issues.append(
                UsageCollectionIssue(
                    source: "tokenball-store-cleanup",
                    message: error.localizedDescription
                )
            )
        }

        collectCodexRecords(
            into: &records,
            processedFingerprints: &processedFingerprints,
            issues: &issues
        )
        do {
            records.append(
                contentsOf: try OpenCodeUsageReader(databaseURL: openCodeDatabaseURL)
                    .readRecords()
            )
        } catch {
            issues.append(
                UsageCollectionIssue(
                    source: "opencode",
                    message: error.localizedDescription
                )
            )
        }
        collectDeepSeekHarnessRecords(
            into: &records,
            processedFingerprints: &processedDeepSeekHarnessFingerprints,
            issues: &issues
        )
        collectGenericJSONRecords(
            into: &records,
            processedFingerprints: &processedJSONFingerprints,
            issues: &issues
        )

        // Keep extension sources isolated: one unavailable or malformed agent
        // must not prevent the built-in sources (or another extension) from
        // being imported during this refresh.
        for source in additionalSources {
            do {
                records.append(contentsOf: try await source.collectRecords())
            } catch {
                let sourceID = source.sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
                issues.append(
                    UsageCollectionIssue(
                        source: sourceID.isEmpty ? "additional-source" : sourceID,
                        message: error.localizedDescription
                    )
                )
            }
        }

        guard !records.isEmpty else {
            importedCodexFingerprints.merge(processedFingerprints) { _, new in new }
            importedJSONFingerprints.merge(processedJSONFingerprints) { _, new in new }
            importedDeepSeekHarnessFingerprints.merge(processedDeepSeekHarnessFingerprints) { _, new in new }
            return UsageCollectionReport(
                discoveredRecordCount: 0,
                importedRecordCount: 0,
                issues: issues
            )
        }

        do {
            let result = try await store.importRecords(records, strategy: .upsert)
            importedCodexFingerprints.merge(processedFingerprints) { _, new in new }
            importedJSONFingerprints.merge(processedJSONFingerprints) { _, new in new }
            importedDeepSeekHarnessFingerprints.merge(processedDeepSeekHarnessFingerprints) { _, new in new }
            return UsageCollectionReport(
                discoveredRecordCount: records.count,
                importedRecordCount: result.importedCount,
                issues: issues
            )
        } catch {
            issues.append(
                UsageCollectionIssue(
                    source: "tokenball-store",
                    message: error.localizedDescription
                )
            )
            return UsageCollectionReport(
                discoveredRecordCount: records.count,
                importedRecordCount: 0,
                issues: issues
            )
        }
    }

    private func collectGenericJSONRecords(
        into records: inout [UsageRecord],
        processedFingerprints: inout [URL: FileFingerprint],
        issues: inout [UsageCollectionIssue]
    ) {
        do {
            try fileManager.createDirectory(
                at: jsonImportDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            issues.append(
                UsageCollectionIssue(source: "json-import", message: error.localizedDescription)
            )
            return
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: jsonImportDirectoryURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            issues.append(
                UsageCollectionIssue(source: "json-import", message: error.localizedDescription)
            )
            return
        }

        for fileURL in files {
            do {
                let values = try fileURL.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                let fingerprint = FileFingerprint(
                    size: values.fileSize ?? 0,
                    modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                )
                guard importedJSONFingerprints[fileURL] != fingerprint else { continue }

                records.append(contentsOf: try genericJSONParser.parse(contentsOf: fileURL))
                processedFingerprints[fileURL] = fingerprint
            } catch {
                issues.append(
                    UsageCollectionIssue(
                        source: "json:\(fileURL.lastPathComponent)",
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    private func collectCodexRecords(
        into records: inout [UsageRecord],
        processedFingerprints: inout [URL: FileFingerprint],
        issues: inout [UsageCollectionIssue]
    ) {
        // The dashboard aggregates the latest 140 days. Older session files
        // never contribute to it, so skip them instead of parsing the entire
        // Codex history on every fresh install.
        let windowStart = Date().addingTimeInterval(-Self.codexWindowSeconds)

        for fileURL in codexJSONLFiles() {
            do {
                let values = try fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey
                ])
                guard values.isRegularFile == true else { continue }
                guard
                    let modificationDate = values.contentModificationDate,
                    modificationDate >= windowStart
                else { continue }
                let fingerprint = FileFingerprint(
                    size: values.fileSize ?? 0,
                    modificationTime: modificationDate.timeIntervalSince1970
                )
                guard importedCodexFingerprints[fileURL] != fingerprint else { continue }

                let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                // Rollout filenames embed a full timestamp and UUID, so the
                // basename is a stable source ID even when Codex moves a
                // session between `sessions/YYYY/MM/DD/` and `archived_sessions/`.
                let sourceID = fileURL.deletingPathExtension().lastPathComponent
                records.append(contentsOf: codexParser.parse(data: data, sourceID: sourceID))
                processedFingerprints[fileURL] = fingerprint
            } catch {
                issues.append(
                    UsageCollectionIssue(
                        source: "codex:\(fileURL.lastPathComponent)",
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    private func codexJSONLFiles() -> [URL] {
        var files: [URL] = []
        if fileManager.fileExists(atPath: codexArchiveDirectoryURL.path),
           let archiveURLs = try? fileManager.contentsOfDirectory(
               at: codexArchiveDirectoryURL,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            files.append(contentsOf: archiveURLs.filter {
                $0.pathExtension.lowercased() == "jsonl"
            })
        }
        if fileManager.fileExists(atPath: codexSessionDirectoryURL.path),
           let enumerator = fileManager.enumerator(
               at: codexSessionDirectoryURL,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            files.append(contentsOf: enumerator.compactMap { $0 as? URL }.filter {
                $0.pathExtension.lowercased() == "jsonl"
            })
        }
        return files.sorted { $0.path < $1.path }
    }

    private func collectDeepSeekHarnessRecords(
        into records: inout [UsageRecord],
        processedFingerprints: inout [URL: FileFingerprint],
        issues: inout [UsageCollectionIssue]
    ) {
        let files = deepSeekHarnessSessionDirectoryURLs.flatMap(deepSeekHarnessFiles(in:))
            .sorted { $0.path < $1.path }
        for fileURL in files {
            do {
                let values = try fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey
                ])
                guard values.isRegularFile == true else { continue }
                let fingerprint = FileFingerprint(
                    size: values.fileSize ?? 0,
                    modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                )
                guard importedDeepSeekHarnessFingerprints[fileURL] != fingerprint else { continue }

                let sourceID = fileURL.deletingLastPathComponent().lastPathComponent
                let data = try zstdDecompressor.decompress(fileURL: fileURL)
                records.append(contentsOf: deepSeekHarnessParser.parse(data: data, sourceID: sourceID))
                processedFingerprints[fileURL] = fingerprint
            } catch {
                issues.append(
                    UsageCollectionIssue(
                        source: "deepseek-harness:\(fileURL.lastPathComponent)",
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    private func deepSeekHarnessFiles(in rootURL: URL) -> [URL] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent == "session.jsonl.zstd"
        }
    }
}

private struct FileFingerprint: Equatable, Sendable {
    let size: Int
    let modificationTime: TimeInterval
}
