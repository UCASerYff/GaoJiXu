import CryptoKit
import Darwin
import Foundation

// The headless target deliberately omits app localization and all UI entry points.
func tS(_ zh: String, _ en: String) -> String { zh }

private enum StageError: Error, CustomStringConvertible {
    case invalidArguments, invalidCurrency, invalidSource, unsupportedLibrary, invalidFinance(String)
    case financeChanged(String), sourceChanged, outputExists, unsafeOutput, temporaryDirectory
    case isolatedLoadFailed, isolatedSaveFailed, snapshotFailed, snapshotMismatch

    var description: String {
        switch self {
        case .invalidArguments: return "Use --source <library.json> --output <new staging directory> --currency <code>."
        case .invalidCurrency: return "The requested currency is not supported."
        case .invalidSource: return "The source must be a readable, valid business library with a modification time."
        case .unsupportedLibrary: return "The source library schema is newer than this tool supports."
        case .invalidFinance(let field): return "Cannot safely compare financial field: \(field)."
        case .financeChanged(let field): return "Refused: isolated loading changed financial field \(field); no snapshot was staged."
        case .sourceChanged: return "Refused: the source changed while staging; no snapshot was staged."
        case .outputExists: return "The output directory must not already exist."
        case .unsafeOutput: return "The staging directory must be outside the source data directory."
        case .temporaryDirectory: return "Could not create an isolated temporary directory."
        case .isolatedLoadFailed: return "The production store could not load the isolated library safely."
        case .isolatedSaveFailed: return "The production store could not persist its isolated copy."
        case .snapshotFailed: return "The production store did not publish a complete schema-2 snapshot."
        case .snapshotMismatch: return "The staged snapshot failed its source-time or dual-copy consistency checks."
        }
    }
}

@main
struct StageWidgetSnapshot {
    private struct Options {
        let source: URL
        let output: URL
        let currency: String
    }

    private struct SourceIdentity: Equatable {
        let sha256: String
        let modifiedAt: Date
        let size: Int
    }

    private struct Manifest: Encodable {
        let tool = "GaoJiXuStageWidgetSnapshot"
        let manifestVersion = 1
        let privateLocalOnly = true
        let sourceSHA256: String
        let sourceModifiedAt: String
        let sourceModifiedAtUnix: Double
        let sourceSizeBytes: Int
        let sourceSchemaVersion: Int
        let sourceUnchanged: Bool
        let financialFieldsEquivalent: Bool
        let snapshotSHA256: String
        let snapshotSchemaVersion: Int
        let snapshotRevision: String
        let dataRevision: String
        let snapshotGeneratedAt: String
        let sourceSavedAt: String
        let writerVersion: String
        let writerBuild: String
        let currency: String
        let timeZoneIdentifier: String
    }

    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().contains("--help") {
            print("Usage: stage_widget_snapshot.sh --source <library.json> --output <new staging directory> --currency CNY")
            print("Reads the source only; writes snapshot.json and private manifest.json to a new staging directory.")
            return
        }
        do {
            try stage(options: parseArguments())
        } catch {
            // Paths, transaction values, and decoder payloads must not leak into console output.
            let message = (error as? StageError)?.description ?? "Staging failed because a file or data validation operation could not be completed."
            FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
            exit(1)
        }
    }

    private static func parseArguments() throws -> Options {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 6 else { throw StageError.invalidArguments }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard ["--source", "--output", "--currency"].contains(key), values[key] == nil, !value.isEmpty else {
                throw StageError.invalidArguments
            }
            values[key] = value
        }
        guard let source = values["--source"], let output = values["--output"], let currency = values["--currency"] else {
            throw StageError.invalidArguments
        }
        guard SavingsCurrency(rawValue: currency) != nil else { throw StageError.invalidCurrency }
        return Options(source: URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath(),
                       output: URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath(),
                       currency: currency)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readSource(_ url: URL) throws -> (Data, SourceIdentity) {
        let fileManager = FileManager.default
        let before = try fileManager.attributesOfItem(atPath: url.path)
        guard before[.type] as? FileAttributeType == .typeRegular,
              let modifiedAt = before[.modificationDate] as? Date,
              let size = before[.size] as? NSNumber else { throw StageError.invalidSource }
        let data = try Data(contentsOf: url)
        let after = try fileManager.attributesOfItem(atPath: url.path)
        guard after[.modificationDate] as? Date == modifiedAt,
              (after[.size] as? NSNumber)?.intValue == size.intValue,
              data.count == size.intValue else { throw StageError.sourceChanged }
        return (data, SourceIdentity(sha256: sha256(data), modifiedAt: modifiedAt, size: data.count))
    }

    /// Compare complete serialized fields, including optional and future nested fields, not only totals.
    /// Array order is immaterial, but duplicate/missing IDs are unsafe to normalize.
    private static func financialFields(_ data: Data) throws -> [String: NSObject] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StageError.invalidSource
        }
        var fields: [String: NSObject] = [:]
        for key in ["accounts", "ledgerEntries", "goals", "records", "budgets", "recurringRules"] {
            let value = object[key]
            if value == nil || value is NSNull {
                guard key != "goals", key != "records" else { throw StageError.invalidFinance(key) }
                fields[key] = NSArray()
                continue
            }
            guard let records = value as? [[String: Any]] else { throw StageError.invalidFinance(key) }
            var ids = Set<String>()
            for record in records {
                guard let id = record["id"] as? String, !id.isEmpty, ids.insert(id).inserted else {
                    throw StageError.invalidFinance(key)
                }
            }
            fields[key] = records.sorted { ($0["id"] as! String) < ($1["id"] as! String) } as NSArray
        }
        if let value = object["lastLedgerAccountID"], !(value is NSNull) {
            guard let id = value as? String else { throw StageError.invalidFinance("lastLedgerAccountID") }
            fields["lastLedgerAccountID"] = id as NSString
        } else {
            fields["lastLedgerAccountID"] = NSNull()
        }
        return fields
    }

    private static func assertFinancialEquality(_ before: [String: NSObject], _ after: [String: NSObject]) throws {
        for field in before.keys.sorted() {
            guard let left = before[field], let right = after[field], left.isEqual(right) else {
                throw StageError.financeChanged(field)
            }
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("gaojixu-stage-widget.XXXXXX").path
        var bytes = Array(template.utf8CString)
        guard let pointer = mkdtemp(&bytes) else { throw StageError.temporaryDirectory }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }

    @MainActor private static func stage(options: Options) throws {
        let fileManager = FileManager.default
        let sourceDirectory = options.source.deletingLastPathComponent().path
        guard options.output.path != sourceDirectory,
              !options.output.path.hasPrefix(sourceDirectory + "/"),
              !options.source.path.hasPrefix(options.output.path + "/") else { throw StageError.unsafeOutput }
        guard !fileManager.fileExists(atPath: options.output.path) else { throw StageError.outputExists }

        let (sourceData, identity) = try readSource(options.source)
        let sourceLibrary: SavingsLibrary
        do { sourceLibrary = try JSONDecoder().decode(SavingsLibrary.self, from: sourceData) }
        catch { throw StageError.invalidSource }
        guard sourceLibrary.version <= SavingsStore.currentSchemaVersion else { throw StageError.unsupportedLibrary }
        let originalFinance = try financialFields(sourceData)
        let temporary = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporary) }
        let isolatedLibrary = temporary.appendingPathComponent("library.json")
        try sourceData.write(to: isolatedLibrary, options: .atomic)
        try fileManager.setAttributes([.modificationDate: identity.modifiedAt, .posixPermissions: 0o600], ofItemAtPath: isolatedLibrary.path)

        let previousDirectory = ProcessInfo.processInfo.environment["GAOJIXU_DATA_DIR"]
        setenv("GAOJIXU_DATA_DIR", temporary.path, 1)
        defer {
            if let previousDirectory { setenv("GAOJIXU_DATA_DIR", previousDirectory, 1) }
            else { unsetenv("GAOJIXU_DATA_DIR") }
        }
        let firstTarget = temporary.appendingPathComponent("Group/gaojixu-widget.json")
        let secondTarget = temporary.appendingPathComponent("Mirror/gaojixu-widget.json")
        let generatedAt = Date()
        let store = SavingsStore(widgetCurrencyCode: options.currency, now: { generatedAt },
                                 snapshotTargets: { [firstTarget, secondTarget] }, snapshotReloader: {})
        guard !store.loadFailed, store.hasLoadedValidLibrary else { throw StageError.isolatedLoadFailed }
        guard store.flushSave() else { throw StageError.isolatedSaveFailed }
        try assertFinancialEquality(originalFinance, financialFields(store.backupData()))

        // The copy is rewritten during load. Restore source provenance before publishing the output.
        store.financialSourceSavedAt = identity.modifiedAt
        store.financesDirty = true
        store.pendingWidgetSnapshot = nil
        store.refreshWidgetSnapshotIfNeeded()
        guard !store.financesDirty, store.pendingWidgetSnapshot == nil, store.widgetSnapshotError == nil else {
            throw StageError.snapshotFailed
        }
        try assertFinancialEquality(originalFinance, financialFields(store.backupData()))
        let snapshotData = try Data(contentsOf: firstTarget)
        guard snapshotData == (try Data(contentsOf: secondTarget)) else { throw StageError.snapshotMismatch }
        let snapshot = try JSONDecoder().decode(GaoJiXuWidgetSnapshot.self, from: snapshotData)
        guard snapshot.schemaVersion == 2, snapshot.currency == options.currency,
              snapshot.dataUpdatedAt == sourceLibrary.financialUpdatedAt,
              let sourceSavedAt = snapshot.sourceSavedAt,
              abs(sourceSavedAt.timeIntervalSince(identity.modifiedAt)) < 0.000001 else { throw StageError.snapshotMismatch }
        let (_, finalIdentity) = try readSource(options.source)
        guard finalIdentity == identity else { throw StageError.sourceChanged }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let manifest = Manifest(sourceSHA256: identity.sha256, sourceModifiedAt: formatter.string(from: identity.modifiedAt),
                                sourceModifiedAtUnix: identity.modifiedAt.timeIntervalSince1970, sourceSizeBytes: identity.size,
                                sourceSchemaVersion: sourceLibrary.version, sourceUnchanged: true, financialFieldsEquivalent: true,
                                snapshotSHA256: sha256(snapshotData), snapshotSchemaVersion: snapshot.schemaVersion,
                                snapshotRevision: snapshot.revision, dataRevision: snapshot.dataRevision,
                                snapshotGeneratedAt: formatter.string(from: snapshot.updatedAt), sourceSavedAt: formatter.string(from: sourceSavedAt),
                                writerVersion: snapshot.writerVersion, writerBuild: snapshot.writerBuild,
                                currency: snapshot.currency, timeZoneIdentifier: snapshot.timeZoneIdentifier)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let outputParent = options.output.deletingLastPathComponent()
        try fileManager.createDirectory(at: outputParent, withIntermediateDirectories: true)
        let prepared = outputParent.appendingPathComponent(".gaojixu-staged-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: prepared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: prepared) }
        for (name, data) in [("snapshot.json", snapshotData), ("manifest.json", try encoder.encode(manifest))] {
            let target = prepared.appendingPathComponent(name)
            try data.write(to: target, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        try fileManager.moveItem(at: prepared, to: options.output)
        print("Prepared snapshot.json and private manifest.json; source financial fields are unchanged.")
        print("Source SHA256: \(identity.sha256)")
        print("Source mtime: \(formatter.string(from: identity.modifiedAt))")
    }
}
