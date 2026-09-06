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
    /// Whether a source or the store changed in a way that can affect an
    /// aggregate snapshot. This lets callers keep a cached dashboard without
    /// mistaking a successful no-op collection for new data.
    public let dataChanged: Bool
    public let issues: [UsageCollectionIssue]

    public init(
        discoveredRecordCount: Int,
        importedRecordCount: Int,
        issues: [UsageCollectionIssue],
        dataChanged: Bool? = nil
    ) {
        self.discoveredRecordCount = discoveredRecordCount
        self.importedRecordCount = importedRecordCount
        // Keep source-compatible behavior for custom UsageCollecting
        // implementations that predate the explicit change signal.
        self.dataChanged = dataChanged ?? (importedRecordCount > 0)
        self.issues = issues
    }
}

/// Imports TokenBall's self-owned local usage sources into its own SQLite
/// store. Source files are fingerprinted after a successful read and only
/// parsed again when their contents change. Extension providers are still
/// called on every collection so they can provide live data; unchanged
/// normalized results are skipped before import. Stable record IDs keep the
/// statistics independent from any external accounting database.
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
    private var importedOpenCodeFingerprint: OpenCodeDatabaseFingerprint?
    private var didInspectOpenCodeDatabase = false
    private var importedAdditionalSourceRecords: [Int: [UsageRecord]] = [:]
    private var didAttemptLegacyCCSwitchPurge = false

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
        var processedOpenCodeFingerprint: OpenCodeDatabaseFingerprint?
        var processedAdditionalSourceRecords: [Int: [UsageRecord]] = [:]
        var dataChanged = false

        // Migration: purge records imported from the removed CC Switch
        // statistics database once per collector instance. The old source is
        // no longer live, so repeating this DELETE on every 60-second refresh
        // only adds avoidable database work.
        if !didAttemptLegacyCCSwitchPurge {
            do {
                let removedCount = try await store.removeRecords(
                    withIDPrefixes: [Self.legacyCCSwitchRecordIDPrefix]
                )
                didAttemptLegacyCCSwitchPurge = true
                dataChanged = removedCount > 0
            } catch {
                issues.append(
                    UsageCollectionIssue(
                        source: "tokenball-store-cleanup",
                        message: error.localizedDescription
                    )
                )
            }
        }

        dataChanged = collectCodexRecords(
            into: &records,
            processedFingerprints: &processedFingerprints,
            issues: &issues
        ) || dataChanged

        let currentOpenCodeFingerprint = openCodeDatabaseFingerprint()
        if !didInspectOpenCodeDatabase || importedOpenCodeFingerprint != currentOpenCodeFingerprint {
            do {
                records.append(
                    contentsOf: try OpenCodeUsageReader(databaseURL: openCodeDatabaseURL)
                        .readRecords()
                )
                processedOpenCodeFingerprint = currentOpenCodeFingerprint
                didInspectOpenCodeDatabase = true
                dataChanged = true
            } catch {
                issues.append(
                    UsageCollectionIssue(
                        source: "opencode",
                        message: error.localizedDescription
                    )
                )
            }
        }

        dataChanged = collectDeepSeekHarnessRecords(
            into: &records,
            processedFingerprints: &processedDeepSeekHarnessFingerprints,
            issues: &issues
        ) || dataChanged
        dataChanged = collectGenericJSONRecords(
            into: &records,
            processedFingerprints: &processedJSONFingerprints,
            issues: &issues
        ) || dataChanged

        // Keep extension sources isolated: one unavailable or malformed agent
        // must not prevent the built-in sources (or another extension) from
        // being imported during this refresh. Providers are intentionally
        // invoked every time; only unchanged normalized output is skipped.
        for (index, source) in additionalSources.enumerated() {
            do {
                let sourceRecords = try await source.collectRecords()
                let canonicalRecords = canonicalize(sourceRecords)
                guard importedAdditionalSourceRecords[index] != canonicalRecords else {
                    continue
                }
                records.append(contentsOf: canonicalRecords)
                processedAdditionalSourceRecords[index] = canonicalRecords
                dataChanged = true
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
            if let processedOpenCodeFingerprint {
                importedOpenCodeFingerprint = processedOpenCodeFingerprint
            }
            importedAdditionalSourceRecords.merge(processedAdditionalSourceRecords) { _, new in new }
            return UsageCollectionReport(
                discoveredRecordCount: 0,
                importedRecordCount: 0,
                issues: issues,
                dataChanged: dataChanged
            )
        }

        do {
            let result = try await store.importRecords(records, strategy: .upsert)
            importedCodexFingerprints.merge(processedFingerprints) { _, new in new }
            importedJSONFingerprints.merge(processedJSONFingerprints) { _, new in new }
            importedDeepSeekHarnessFingerprints.merge(processedDeepSeekHarnessFingerprints) { _, new in new }
            if let processedOpenCodeFingerprint {
                importedOpenCodeFingerprint = processedOpenCodeFingerprint
            }
            importedAdditionalSourceRecords.merge(processedAdditionalSourceRecords) { _, new in new }
            return UsageCollectionReport(
                discoveredRecordCount: records.count,
                importedRecordCount: result.importedCount,
                issues: issues,
                dataChanged: dataChanged || result.importedCount > 0
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
                issues: issues,
                dataChanged: dataChanged
            )
        }
    }

    private func collectGenericJSONRecords(
        into records: inout [UsageRecord],
        processedFingerprints: inout [URL: FileFingerprint],
        issues: inout [UsageCollectionIssue]
    ) -> Bool {
        var didChange = false
        do {
            try fileManager.createDirectory(
                at: jsonImportDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            issues.append(
                UsageCollectionIssue(source: "json-import", message: error.localizedDescription)
            )
            return false
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
            return false
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
                didChange = true
            } catch {
                issues.append(
                    UsageCollectionIssue(
                        source: "json:\(fileURL.lastPathComponent)",
                        message: error.localizedDescription
                    )
                )
            }
        }
        return didChange
    }

    private func collectCodexRecords(
        into records: inout [UsageRecord],
        processedFingerprints: inout [URL: FileFingerprint],
        issues: inout [UsageCollectionIssue]
    ) -> Bool {
        var didChange = false
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
                didChange = true
            } catch {
                issues.append(
                    UsageCollectionIssue(
                        source: "codex:\(fileURL.lastPathComponent)",
                        message: error.localizedDescription
                    )
                )
            }
        }
        return didChange
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
    ) -> Bool {
        var didChange = false
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
                didChange = true
            } catch {
                issues.append(
                    UsageCollectionIssue(
                        source: "deepseek-harness:\(fileURL.lastPathComponent)",
                        message: error.localizedDescription
                    )
                )
            }
        }
        return didChange
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

    /// SQLite may keep the newest committed pages in a write-ahead log while
    /// the main database file's mtime and size stay unchanged. Include the
    /// database and WAL, but deliberately omit SQLite's `-shm`: opening a
    /// read-only connection can update that lock/shared-memory sidecar even
    /// when usage data did not change.
    private func openCodeDatabaseFingerprint() -> OpenCodeDatabaseFingerprint {
        OpenCodeDatabaseFingerprint(
            database: fileFingerprint(at: openCodeDatabaseURL),
            wal: fileFingerprint(at: URL(fileURLWithPath: openCodeDatabaseURL.path + "-wal"))
        )
    }

    private func fileFingerprint(at url: URL) -> FileFingerprint? {
        // FileManager attributes avoid URL resource-value caching. The same
        // URL instance may be retained by an integration while SQLite is
        // writing the database between timer ticks.
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular
        else {
            return nil
        }
        return FileFingerprint(
            size: (attributes[.size] as? NSNumber).map { Int(truncating: $0) } ?? 0,
            modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        )
    }

    /// Providers are allowed to return rows in whatever order their source
    /// uses. Canonicalizing by stable identity avoids treating a harmless
    /// ordering change as a data change while preserving all row fields for
    /// the upsert.
    private func canonicalize(_ records: [UsageRecord]) -> [UsageRecord] {
        records.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            if $0.agent != $1.agent { return $0.agent < $1.agent }
            return $0.model < $1.model
        }
    }
}

private struct FileFingerprint: Equatable, Sendable {
    let size: Int
    let modificationTime: TimeInterval
}

private struct OpenCodeDatabaseFingerprint: Equatable, Sendable {
    let database: FileFingerprint?
    let wal: FileFingerprint?
}
