import Foundation

/// Token counters recorded by local Codex sessions. Cached and reasoning tokens
/// are subsets of input and output respectively, never additions to the total.
struct DailyTokenDay: Codable, Equatable {
    let date: String
    let totalTokens: Int64
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
}

struct DailyTokenModelDay: Codable, Equatable {
    let date: String
    /// The recorded model identifier, or "unknown" when unavailable.
    let model: String
    let totalTokens: Int64
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
}

struct DailyTokenUsageSnapshot {
    let days: [DailyTokenDay]
    let checkedAt: Date
    let sourceFileCount: Int
    let unreadableFileCount: Int
    let skippedRecordCount: Int
    let retainedFileCount: Int
    let persistenceWarning: Bool
    let coverageSummary: String
    let logURL: URL
    var modelDays: [DailyTokenModelDay] = []

    static let disclaimer = "Local Codex sessions on this Mac only. ChatGPT chats, other devices, and API billing are not included."
    var disclaimer: String { Self.disclaimer }
    var hasCoverageWarning: Bool {
        unreadableFileCount > 0 || skippedRecordCount > 0 || retainedFileCount > 0 || persistenceWarning
    }
}

/// Reads token counters and recorded model identifiers; never stores prompts, replies, or credentials.
/// The compact local log also caches file offsets because session histories can
/// contain several gigabytes of unrelated conversation and image data.
enum DailyTokenUsageReader {
    private static let lock = NSLock()
    private static var memoryCache: Cache?
    private static var needsSave = false
    private static let cacheVersion = 2
    private static let maxLineBytes = 1_048_576

    static func read() throws -> DailyTokenUsageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let codexRoot = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".codex", isDirectory: true)
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
            .appendingPathComponent("Codex Usage", isDirectory: true)
        let logURL = support.appendingPathComponent("daily-token-usage.json")
        var cache = memoryCache ?? ((try? Data(contentsOf: logURL)).flatMap {
            try? JSONDecoder().decode(Cache.self, from: $0)
        } ?? Cache())

        var present = Set<String>()
        var unreadable = 0
        var unavailableDirectories = 0
        var changed = cache.timeZone != TimeZone.autoupdatingCurrent.identifier || cache.version != cacheVersion
        // Version 1 already contains trustworthy numeric history. Keep it while
        // available sources are rescanned once for recorded model context.
        cache.version = cacheVersion
        for directory in ["sessions", "archived_sessions"] {
            let root = codexRoot.appendingPathComponent(directory, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                // A new installation may have no archive directory yet.
                if directory == "sessions" { unavailableDirectories += 1 }
                continue
            }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles], errorHandler: { _, _ in
                unavailableDirectories += 1
                return true
            }) else {
                unavailableDirectories += 1
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let path = url.path
                present.insert(path)
                do {
                    let attributes = try fm.attributesOfItem(atPath: path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                    let old = cache.files[path]
                    let needsEnrichment = old.map { $0.modelAttributionVersion != cacheVersion } ?? false
                    if let old, !needsEnrichment, old.size == size, old.modified == modified, old.inode == inode {
                        continue
                    }
                    let append = old.map { !needsEnrichment && $0.inode == inode && size > $0.size } ?? false
                    let parsed = try scan(url: url, previous: append ? old : nil, size: size,
                                          modified: modified, inode: inode)
                    // Attribution enrichment never deletes recorded numeric
                    // history, including events no longer present in the source.
                    cache.files[path] = needsEnrichment && old != nil ? enrich(old!, with: parsed) : parsed
                    changed = true
                } catch { unreadable += 1 }
            }
        }

        // A move to archived_sessions leaves the same events under another path.
        // Drop the old cache only when the present source covers all its events.
        let currentFiles = cache.files.filter { present.contains($0.key) }
        for (path, old) in cache.files where !present.contains(path) {
            guard let replacement = currentFiles.first(where: {
                $0.value.ownerID == old.ownerID && $0.value.ownerID != nil &&
                    Set($0.value.events).isSuperset(of: Set(old.events))
            }) else { continue }
            if replacement.value.events.count >= old.events.count {
                // Preserve known context when the archive copy has fewer model
                // fields than the already recorded source.
                cache.files[replacement.key] = enrich(old, with: cache.files[replacement.key]!)
                cache.files.removeValue(forKey: path)
                changed = true
            }
        }
        let retained = cache.files.keys.filter { !present.contains($0) }.count
        let result = aggregate(Array(cache.files.values), timeZone: .autoupdatingCurrent)
        let skipped = cache.files.values.reduce(0) { $0 + $1.skippedRecords } + result.skipped
        let checkedAt = Date()
        let days = result.days
        cache.checkedAt = checkedAt
        cache.days = days
        cache.modelDays = result.modelDays
        cache.timeZone = TimeZone.autoupdatingCurrent.identifier
        var persistenceWarning = false
        if changed || memoryCache == nil || needsSave {
            do {
                try fm.createDirectory(at: support, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(cache)
                try data.write(to: logURL, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
            } catch { persistenceWarning = true }
        }
        memoryCache = cache
        needsSave = persistenceWarning
        let inaccessible = unreadable + unavailableDirectories
        var coverage = present.isEmpty && days.isEmpty ? "No local token records found" : "\(present.count) local session files"
        if inaccessible > 0 { coverage += " · \(inaccessible) sources unavailable" }
        if skipped > 0 { coverage += " · \(skipped) records could not be counted" }
        if retained > 0 { coverage += " · using history from \(retained) missing files" }
        if persistenceWarning { coverage += " · local log could not be saved" }
        return DailyTokenUsageSnapshot(days: days, checkedAt: checkedAt, sourceFileCount: present.count,
            unreadableFileCount: inaccessible, skippedRecordCount: skipped,
            retainedFileCount: retained, persistenceWarning: persistenceWarning,
            coverageSummary: coverage, logURL: logURL, modelDays: result.modelDays)
    }

    private struct Tokens: Codable, Equatable, Hashable {
        var input: Int64
        var cached: Int64
        var output: Int64
        var reasoning: Int64
        var total: Int64
        static let zero = Tokens(input: 0, cached: 0, output: 0, reasoning: 0, total: 0)

        init(input: Int64, cached: Int64, output: Int64, reasoning: Int64, total: Int64) {
            self.input = input; self.cached = cached; self.output = output
            self.reasoning = reasoning; self.total = total
        }
        init?(_ raw: [String: Any]?) {
            guard let raw, let input = Self.integer(raw["input_tokens"]),
                  let output = Self.integer(raw["output_tokens"]),
                  let total = Self.integer(raw["total_tokens"]),
                  let cached = Self.integer(raw["cached_input_tokens"]),
                  let reasoning = Self.integer(raw["reasoning_output_tokens"]),
                  input <= Int64.max - output, total == input + output,
                  cached <= input, reasoning <= output else { return nil }
            self.init(input: input, cached: cached, output: output, reasoning: reasoning, total: total)
        }
        private static func integer(_ value: Any?) -> Int64? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let decimal = number.stringValue
            guard let count = Int64(decimal), count >= 0 else { return nil }
            return count
        }
        func delta(after old: Tokens) -> Tokens? {
            guard input >= old.input, cached >= old.cached, output >= old.output,
                  reasoning >= old.reasoning, total >= old.total else { return nil }
            return Tokens(input: input - old.input, cached: cached - old.cached,
                          output: output - old.output, reasoning: reasoning - old.reasoning,
                          total: total - old.total)
        }
        func adding(_ other: Tokens) -> Tokens? {
            let fields = [(input, other.input), (cached, other.cached), (output, other.output),
                          (reasoning, other.reasoning), (total, other.total)]
            guard fields.allSatisfy({ $0.0 <= Int64.max - $0.1 }) else { return nil }
            return Tokens(input: input + other.input, cached: cached + other.cached,
                          output: output + other.output, reasoning: reasoning + other.reasoning,
                          total: total + other.total)
        }
    }
    private struct Event: Codable, Hashable {
        var owner: String
        var timestamp: Date
        var counters: Tokens
        var last: Tokens?
        var model: String? = nil

        // Model context is enrichment, not event identity. An old unknown copy
        // and its enriched copy must remain the same numeric event.
        static func == (lhs: Event, rhs: Event) -> Bool {
            lhs.owner == rhs.owner && lhs.timestamp == rhs.timestamp &&
                lhs.counters == rhs.counters && lhs.last == rhs.last
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(owner); hasher.combine(timestamp)
            hasher.combine(counters); hasher.combine(last)
        }
    }
    private struct FileRecord: Codable {
        var size: UInt64 = 0
        var modified: TimeInterval = 0
        var inode: UInt64 = 0
        var offset: UInt64 = 0
        var ownerID: String?
        var createdAt: Date?
        var forkedFromID: String?
        var historyOwnerID: String?
        var inheritedBaseline: Event?
        var currentModel: String?
        var currentModelOwnerID: String?
        var modelAttributionVersion: Int?
        var events: [Event] = []
        var skippedRecords = 0
    }
    private struct Cache: Codable {
        var version = cacheVersion
        var checkedAt: Date?
        var timeZone: String?
        var days: [DailyTokenDay] = []
        var modelDays: [DailyTokenModelDay]?
        var files: [String: FileRecord] = [:]
    }
    private static func merge(_ old: Event?, _ incoming: Event) -> Event {
        guard let old else { return incoming }
        var result = old
        if old.model == nil {
            result.model = incoming.model
        } else if let model = incoming.model, model != old.model {
            // Conflicting explicit context is ambiguous; do not choose a model
            // based on dictionary or filesystem enumeration order.
            result.model = "unknown"
        }
        return result
    }
    private static func enrich(_ old: FileRecord, with parsed: FileRecord) -> FileRecord {
        var result = parsed
        var events: [Event: Event] = [:]
        for event in old.events + parsed.events { events[event] = merge(events[event], event) }
        result.events = Array(events.values)
        if result.ownerID == nil {
            result.ownerID = old.ownerID
            result.createdAt = old.createdAt
            result.forkedFromID = old.forkedFromID
        }
        if result.inheritedBaseline == nil, result.ownerID == old.ownerID {
            result.inheritedBaseline = old.inheritedBaseline.map { events[$0] ?? $0 }
        }
        return result
    }

    private static func scan(url: URL, previous: FileRecord?, size: UInt64,
                             modified: TimeInterval, inode: UInt64) throws -> FileRecord {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var file = previous ?? FileRecord()
        try handle.seek(toOffset: file.offset)
        var readPosition = file.offset
        var line = Data()
        var oversized = false
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        func finishLine() {
            if oversized {
                // Only candidate metadata/token lines matter; image and message
                // lines may be huge and are intentionally ignored.
                if isCandidate(line) { file.skippedRecords += 1 }
                if line.range(of: Data("\"turn_context\"".utf8)) != nil {
                    file.currentModel = nil
                    file.currentModelOwnerID = nil
                }
            } else { consume(line, into: &file, formatter: formatter, plainFormatter: plainFormatter) }
            line.removeAll(keepingCapacity: true)
            oversized = false
        }
        // Read only the size seen at enumeration; a concurrently growing file
        // is picked up from the last complete line on the next refresh.
        while readPosition < size {
            let requested = Int(min(UInt64(262_144), size - readPosition))
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let end = chunk[start...].firstIndex(of: 0x0A) ?? chunk.endIndex
                if !oversized {
                    let count = end - start
                    let room = maxLineBytes - line.count
                    line.append(chunk[start..<(start + min(count, room))])
                    oversized = count > room
                }
                if end < chunk.endIndex {
                    finishLine()
                    file.offset = readPosition + UInt64(end - chunk.startIndex + 1)
                    start = end + 1
                } else { start = end }
            }
            readPosition += UInt64(chunk.count)
        }
        // An unfinished append is not a corrupt record, and its bytes are
        // revisited later. No conversation content is retained in the cache.
        file.size = size; file.modified = modified; file.inode = inode
        file.modelAttributionVersion = cacheVersion
        return file
    }
    private static func isCandidate(_ data: Data) -> Bool {
        data.range(of: Data("\"token_count\"".utf8)) != nil ||
        data.range(of: Data("\"session_meta\"".utf8)) != nil ||
        data.range(of: Data("\"turn_context\"".utf8)) != nil
    }
    private static func recordedModel(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 128,
              model.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return model
    }
    private static func consume(_ data: Data, into file: inout FileRecord,
                                formatter: ISO8601DateFormatter, plainFormatter: ISO8601DateFormatter) {
        guard isCandidate(data) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else {
            file.skippedRecords += 1
            if data.range(of: Data("\"turn_context\"".utf8)) != nil {
                file.currentModel = nil
                file.currentModelOwnerID = nil
            }
            return
        }
        func date(_ value: Any?) -> Date? {
            guard let raw = value as? String else { return nil }
            return formatter.date(from: raw) ?? plainFormatter.date(from: raw)
        }
        if object["type"] as? String == "session_meta" {
            guard let id = payload["id"] as? String ?? payload["session_id"] as? String, !id.isEmpty else {
                file.skippedRecords += 1
                return
            }
            if file.ownerID == nil {
                file.ownerID = id
                file.createdAt = date(payload["timestamp"] ?? object["timestamp"])
                file.forkedFromID = payload["forked_from_id"] as? String
            }
            file.historyOwnerID = id
            // A copied session header is not proof that the descendant uses
            // the ancestor's model. Wait for its recorded turn context.
            file.currentModel = nil
            file.currentModelOwnerID = nil
            return
        }
        if object["type"] as? String == "turn_context" {
            guard let timestamp = date(object["timestamp"]) else {
                file.currentModel = nil
                file.currentModelOwnerID = nil
                return
            }
            let inherited = file.createdAt.map { timestamp < $0 } ?? false
            file.currentModel = recordedModel(payload["model"])
            file.currentModelOwnerID = inherited ? file.historyOwnerID : file.ownerID
            return
        }
        guard object["type"] as? String == "event_msg", payload["type"] as? String == "token_count" else { return }
        // Some token_count events only update rate limits and have null info.
        guard let info = payload["info"] as? [String: Any] else { return }
        guard let counters = Tokens(info["total_token_usage"] as? [String: Any]),
              let timestamp = date(object["timestamp"]), let owner = file.ownerID else {
            file.skippedRecords += 1
            return
        }
        let inherited = file.createdAt.map { timestamp < $0 } ?? false
        let eventOwner = inherited ? (file.historyOwnerID ?? file.forkedFromID ?? owner) : owner
        let event = Event(owner: eventOwner, timestamp: timestamp, counters: counters,
                          last: Tokens(info["last_token_usage"] as? [String: Any]),
                          model: file.currentModelOwnerID == eventOwner ? file.currentModel : nil)
        if inherited {
            if file.inheritedBaseline == nil || timestamp >= file.inheritedBaseline!.timestamp {
                file.inheritedBaseline = event
            }
        }
        file.events.append(event)
    }

    private struct ModelDayKey: Hashable {
        let date: String
        let model: String
    }
    private static func aggregate(_ files: [FileRecord], timeZone: TimeZone) ->
        (days: [DailyTokenDay], modelDays: [DailyTokenModelDay], skipped: Int) {
        // Exact event copies (including archived files and inherited fork
        // history) count once, while independent subagents count separately.
        var groups: [String: [Event: Event]] = [:]
        var baselines: [String: Event] = [:]
        for file in files {
            for event in file.events {
                groups[event.owner, default: [:]][event] = merge(groups[event.owner]?[event], event)
            }
            if let owner = file.ownerID, let baseline = file.inheritedBaseline,
               baselines[owner] == nil || baseline.timestamp > baselines[owner]!.timestamp {
                baselines[owner] = baseline
            }
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.timeZone = timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        var days: [String: Tokens] = [:]
        var models: [ModelDayKey: Tokens] = [:]
        var skipped = 0
        for owner in groups.keys.sorted() {
            let events = groups[owner]!.values
            var previous = baselines[owner]?.counters
            var previousModel = baselines[owner]?.model
            let baselineDate = baselines[owner]?.timestamp
            for event in events.sorted(by: {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                if $0.counters.total != $1.counters.total { return $0.counters.total < $1.counters.total }
                return $0.counters.input < $1.counters.input
            }) {
                // The baseline describes copied history and is never itself a
                // newly consumed token increment in the descendant.
                if let baselineDate, event.timestamp <= baselineDate { continue }
                let increment: Tokens?
                if let prior = previous {
                    if event.counters.total == prior.total {
                        // Repeated cumulative snapshots often have new timestamps.
                        // A changed breakdown with the same total is a correction,
                        // not a second request or a counter reset.
                        if event.counters != prior { skipped += 1 }
                        previous = event.counters
                        continue
                    }
                    if event.counters.total < prior.total {
                        increment = event.counters
                    } else {
                        increment = event.counters.delta(after: prior)
                        if increment == nil { skipped += 1 }
                    }
                } else if event.last == event.counters || event.counters == .zero {
                    increment = event.counters
                } else {
                    // Missing/truncated history or a fork with inherited counters:
                    // the most recent request is safe if its breakdown is known.
                    increment = event.last
                    skipped += 1
                }
                var model = event.model
                if previous != nil, previousModel != event.model, increment != event.last {
                    // A delta spanning missing requests around a model switch
                    // cannot all be assigned to the newest recorded model.
                    model = nil
                }
                previous = event.counters
                previousModel = event.model
                guard let increment else { continue }
                let day = dayFormatter.string(from: event.timestamp)
                let key = ModelDayKey(date: day, model: model ?? "unknown")
                guard let combined = (days[day] ?? .zero).adding(increment),
                      let modelCombined = (models[key] ?? .zero).adding(increment) else {
                    skipped += 1
                    continue
                }
                days[day] = combined
                models[key] = modelCombined
            }
        }
        return (days.keys.sorted(by: >).map { date in
            let tokens = days[date]!
            return DailyTokenDay(date: date, totalTokens: tokens.total, inputTokens: tokens.input,
                cachedInputTokens: tokens.cached, outputTokens: tokens.output,
                reasoningOutputTokens: tokens.reasoning)
        }, models.keys.sorted(by: {
            $0.date == $1.date ? $0.model < $1.model : $0.date > $1.date
        }).map { key in
            let tokens = models[key]!
            return DailyTokenModelDay(date: key.date, model: key.model, totalTokens: tokens.total,
                inputTokens: tokens.input, cachedInputTokens: tokens.cached,
                outputTokens: tokens.output, reasoningOutputTokens: tokens.reasoning)
        }, skipped)
    }

    /// Pure fixtures: these checks never read a real session or credential file.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        let zone = TimeZone(identifier: "Asia/Tokyo")!
        let formatter = ISO8601DateFormatter()
        func stamp(_ value: String) -> Date { formatter.date(from: value)! }
        let a = Tokens(input: 100, cached: 60, output: 20, reasoning: 8, total: 120)
        let b = Tokens(input: 150, cached: 90, output: 30, reasoning: 12, total: 180)
        let reset = Tokens(input: 10, cached: 2, output: 3, reasoning: 1, total: 13)
        let t1 = stamp("2026-10-01T14:59:59Z")
        let t2 = stamp("2026-10-01T15:00:00Z")
        let t3 = stamp("2026-10-01T15:00:01Z")
        let e1 = Event(owner: "root", timestamp: t1, counters: a, last: a)
        let e2 = Event(owner: "root", timestamp: t2, counters: b, last: b.delta(after: a))
        var original = FileRecord(); original.ownerID = "root"; original.events = [e1, e2]
        var archiveCopy = original
        archiveCopy.events.append(Event(owner: "root", timestamp: t3, counters: b, last: e2.last))
        let basic = aggregate([original, archiveCopy], timeZone: zone)
        if basic.days.map(\.date) != ["2026-10-02", "2026-10-01"] || basic.days.map(\.totalTokens) != [60, 120] {
            failures.append("Daily midnight attribution, duplicate files, or repeated snapshots")
        }
        var sameTimestamp = FileRecord(); sameTimestamp.ownerID = "same-millisecond"
        sameTimestamp.events = [Event(owner: "same-millisecond", timestamp: t1, counters: a, last: a),
                               Event(owner: "same-millisecond", timestamp: t1, counters: b, last: e2.last)]
        if aggregate([sameTimestamp], timeZone: zone).days.first?.totalTokens != 180 {
            failures.append("Distinct cumulative events at the same timestamp")
        }
        if basic.days.reduce(0, { $0 + $1.totalTokens }) != 180 ||
            basic.days.reduce(0, { $0 + $1.cachedInputTokens }) != 90 ||
            basic.days.reduce(0, { $0 + $1.reasoningOutputTokens }) != 12 {
            failures.append("Cached/reasoning subsets must not inflate totals")
        }
        var fork = FileRecord(); fork.ownerID = "fork"; fork.inheritedBaseline = e1
        fork.events = [e1, Event(owner: "fork", timestamp: t2, counters: b, last: e2.last)]
        if aggregate([original, fork], timeZone: zone).days.reduce(0, { $0 + $1.totalTokens }) != 240 {
            failures.append("Fork baseline or inherited history deduplication")
        }
        var freshSubagent = FileRecord(); freshSubagent.ownerID = "subagent"; freshSubagent.inheritedBaseline = e2
        freshSubagent.events = [Event(owner: "subagent", timestamp: t3, counters: reset, last: reset)]
        if aggregate([original, freshSubagent], timeZone: zone).days.reduce(0, { $0 + $1.totalTokens }) != 193 {
            failures.append("Fresh subagent counters after an inherited baseline")
        }
        original.events.append(Event(owner: "root", timestamp: t3, counters: reset, last: reset))
        if aggregate([original], timeZone: zone).days.reduce(0, { $0 + $1.totalTokens }) != 193 {
            failures.append("Cumulative counter reset")
        }
        if Tokens(["input_tokens": 100, "cached_input_tokens": 60, "output_tokens": 20, "reasoning_output_tokens": 8, "total_tokens": 180]) != nil ||
            Tokens(["input_tokens": true, "cached_input_tokens": 0, "output_tokens": 0, "reasoning_output_tokens": 0, "total_tokens": 1]) != nil {
            failures.append("Invalid numeric usage must not fabricate counts")
        }
        var noBaseline = FileRecord(); noBaseline.ownerID = "missing"
        noBaseline.events = [Event(owner: "missing", timestamp: t2, counters: b, last: nil)]
        let missing = aggregate([noBaseline], timeZone: zone)
        if !missing.days.isEmpty || missing.skipped != 1 { failures.append("Unknown baseline must show incomplete coverage") }
        let jsonFormatter = ISO8601DateFormatter()
        jsonFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func fixture(_ object: [String: Any]) -> Data {
            try! JSONSerialization.data(withJSONObject: object)
        }
        var parsed = FileRecord()
        consume(fixture(["timestamp": "2026-10-01T15:00:00Z", "type": "session_meta",
                         "payload": ["id": "child", "session_id": "root", "forked_from_id": "root",
                                     "timestamp": "2026-10-01T15:00:00Z"]]),
                into: &parsed, formatter: jsonFormatter, plainFormatter: formatter)
        consume(fixture(["timestamp": "2026-10-01T15:00:00Z", "type": "session_meta",
                         "payload": ["id": "root", "session_id": "root", "timestamp": "2026-10-01T14:00:00Z"]]),
                into: &parsed, formatter: jsonFormatter, plainFormatter: formatter)
        let rawA: [String: Any] = ["input_tokens": 100, "cached_input_tokens": 60,
                                  "output_tokens": 20, "reasoning_output_tokens": 8, "total_tokens": 120]
        let rawB: [String: Any] = ["input_tokens": 150, "cached_input_tokens": 90,
                                  "output_tokens": 30, "reasoning_output_tokens": 12, "total_tokens": 180]
        for (timestamp, raw) in [("2026-10-01T14:59:59Z", rawA), ("2026-10-01T15:00:01Z", rawB)] {
            consume(fixture(["timestamp": timestamp, "type": "turn_context",
                             "payload": ["model": timestamp < "2026-10-01T15:00:00Z" ? "model-a" : "model-b"]]),
                    into: &parsed, formatter: jsonFormatter, plainFormatter: formatter)
            let last: [String: Any] = timestamp < "2026-10-01T15:00:00Z" ? rawA :
                ["input_tokens": 50, "cached_input_tokens": 30, "output_tokens": 10,
                 "reasoning_output_tokens": 4, "total_tokens": 60]
            consume(fixture(["timestamp": timestamp, "type": "event_msg",
                             "payload": ["type": "token_count", "info": ["total_token_usage": raw, "last_token_usage": last]]]),
                    into: &parsed, formatter: jsonFormatter, plainFormatter: formatter)
        }
        if parsed.ownerID != "child" || parsed.events.map(\.owner) != ["root", "child"] ||
            parsed.inheritedBaseline?.counters != a {
            failures.append("Fork metadata and shared root session_id attribution")
        }
        let parsedDays = aggregate([parsed], timeZone: zone)
        if parsedDays.days.map(\.totalTokens) != [60, 120] {
            failures.append("Copied history parser must retain the fork baseline")
        }
        func reconciles(_ result: (days: [DailyTokenDay], modelDays: [DailyTokenModelDay], skipped: Int)) -> Bool {
            result.days.allSatisfy { day in
                let models = result.modelDays.filter { $0.date == day.date }
                return models.reduce(Int64(0), { $0 + $1.totalTokens }) == day.totalTokens &&
                    models.reduce(Int64(0), { $0 + $1.inputTokens }) == day.inputTokens &&
                    models.reduce(Int64(0), { $0 + $1.cachedInputTokens }) == day.cachedInputTokens &&
                    models.reduce(Int64(0), { $0 + $1.outputTokens }) == day.outputTokens &&
                    models.reduce(Int64(0), { $0 + $1.reasoningOutputTokens }) == day.reasoningOutputTokens
            }
        }
        if parsed.events.map(\.model) != ["model-a", "model-b"] ||
            parsedDays.modelDays.map(\.model) != ["model-b", "model-a"] || !reconciles(parsedDays) {
            failures.append("Recorded fork contexts and per-model totals must reconcile")
        }
        var attributed = FileRecord(); attributed.ownerID = "root"
        var modeledFirst = e1; modeledFirst.model = "model-a"
        var modeledSecond = e2; modeledSecond.model = "model-b"
        attributed.events = [modeledFirst, modeledSecond,
            Event(owner: "root", timestamp: t3, counters: reset, last: reset)]
        var attributionDuplicate = FileRecord(); attributionDuplicate.ownerID = "root"; attributionDuplicate.events = [e1, e2]
        let attribution = aggregate([attributed, attributionDuplicate], timeZone: zone)
        if attribution.modelDays.map(\.model) != ["model-b", "unknown", "model-a"] ||
            attribution.modelDays.map(\.totalTokens) != [60, 13, 120] || !reconciles(attribution) {
            failures.append("Model switching, unknown context, reset, and duplicate reconciliation")
        }
        var uncertainSwitch = FileRecord(); uncertainSwitch.ownerID = "root"
        uncertainSwitch.events = [modeledFirst,
            Event(owner: "root", timestamp: t2, counters: b, last: reset, model: "model-b")]
        let uncertain = aggregate([uncertainSwitch], timeZone: zone)
        if uncertain.modelDays.first?.model != "unknown" || !reconciles(uncertain) {
            failures.append("An unitemized delta across a model switch must stay unknown")
        }
        var conflict = attributed
        conflict.events = [modeledSecond]
        conflict.events[0].model = "different-model"
        let conflicted = aggregate([attributed, conflict], timeZone: zone)
        let reverseConflict = aggregate([conflict, attributed], timeZone: zone)
        if conflicted.modelDays != reverseConflict.modelDays || !reconciles(conflicted) ||
            conflicted.modelDays.first(where: { $0.date == "2026-10-02" && $0.model == "unknown" })?.totalTokens != 73 {
            failures.append("Conflicting duplicate contexts must stay unknown and count once")
        }
        do {
            // Remove precisely the fields absent from the original numeric cache.
            var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
            for key in ["currentModel", "currentModelOwnerID", "modelAttributionVersion"] { oldJSON.removeValue(forKey: key) }
            oldJSON["events"] = (oldJSON["events"] as! [[String: Any]]).map { raw in
                var event = raw; event.removeValue(forKey: "model"); return event
            }
            let legacyFile = try JSONDecoder().decode(FileRecord.self,
                from: JSONSerialization.data(withJSONObject: oldJSON))
            let legacy = aggregate([legacyFile], timeZone: zone)
            let migrated = aggregate([enrich(legacyFile, with: attributed)], timeZone: zone)
            if migrated.days != legacy.days || !reconciles(migrated) ||
                aggregate([legacyFile], timeZone: zone).modelDays.contains(where: { $0.model != "unknown" }) {
                failures.append("Legacy enrichment must preserve numbers and missing-source unknown models")
            }
            // An incremental append retains its explicit model through the cache;
            // a new context lacking model information clears that attribution.
            var continued = try JSONDecoder().decode(FileRecord.self, from: JSONEncoder().encode(parsed))
            consume(fixture(["timestamp": "2026-10-01T15:00:02Z", "type": "event_msg",
                             "payload": ["type": "token_count", "info": ["total_token_usage": rawB, "last_token_usage": rawB]]]),
                    into: &continued, formatter: jsonFormatter, plainFormatter: formatter)
            if continued.events.last?.model != "model-b" { failures.append("Incremental cached model context") }
            consume(fixture(["timestamp": "2026-10-01T15:00:03Z", "type": "turn_context", "payload": [:]]),
                    into: &continued, formatter: jsonFormatter, plainFormatter: formatter)
            consume(fixture(["timestamp": "2026-10-01T15:00:04Z", "type": "event_msg",
                             "payload": ["type": "token_count", "info": ["total_token_usage": rawB, "last_token_usage": rawB]]]),
                    into: &continued, formatter: jsonFormatter, plainFormatter: formatter)
            if continued.events.last?.model != nil { failures.append("Absent model must not reuse an older turn's model") }
        } catch { failures.append("Model attribution migration/cache fixtures: \(error.localizedDescription)") }
        return failures
    }
}
