import AppKit
import EventKit
import Foundation
import OSLog
import Ontology

private let log = Logger.service("reminders")

/// Wraps a PlanAction so we can add `isSubtask` / `parentId` to the JSON output
/// without modifying the upstream Ontology package. encode() delegates to
/// PlanAction's encoder (keyed container) and writes our extra keys into the
/// same underlying object, producing flat JSON.
private struct ReminderResult: Encodable {
    let action: PlanAction
    let isSubtask: Bool?
    let parentId: String?

    private enum ExtraKey: String, CodingKey {
        case isSubtask
        case parentId
    }

    func encode(to encoder: Encoder) throws {
        try action.encode(to: encoder)
        var container = encoder.container(keyedBy: ExtraKey.self)
        if let isSubtask {
            try container.encode(isSubtask, forKey: .isSubtask)
        }
        if let parentId {
            try container.encode(parentId, forKey: .parentId)
        }
    }
}

final class RemindersService: Service {
    private let eventStore = EKEventStore()

    static let shared = RemindersService()

    /// Runs an AppleScript against Reminders.app to learn which reminders in the
    /// given calendars are top-level (i.e., not subtasks). EventKit returns every
    /// reminder including children but doesn't reveal the parent/child link;
    /// AppleScript's `every reminder of list` returns only the top-level set, so
    /// the difference identifies subtasks. Returns nil if AppleScript fails
    /// (e.g. Automation permission denied) — callers should treat that as "we
    /// don't know" and omit the flag rather than guess.
    private func topLevelReminderIdentifiers(in calendars: [EKCalendar]) -> Set<String>? {
        guard !calendars.isEmpty else { return [] }

        let listClauses = calendars.map { "list id \"\($0.calendarIdentifier)\"" }
            .joined(separator: ", ")
        let source = """
            tell application "Reminders"
                set out to {}
                repeat with l in {\(listClauses)}
                    set out to out & (id of every reminder of l)
                end repeat
                return out
            end tell
            """

        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            log.warning(
                "AppleScript subtask probe failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }

        var ids = Set<String>()
        let prefix = "x-apple-reminder://"
        if result.descriptorType == typeAEList {
            // numberOfItems can be 0 for an empty AE list; guard before iterating
            // because Swift's `1...0` is an invalid ClosedRange and traps.
            if result.numberOfItems > 0 {
                for i in 1...result.numberOfItems {
                    guard let item = result.atIndex(i), let s = item.stringValue else { continue }
                    ids.insert(s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s)
                }
            }
        } else if let s = result.stringValue {
            // Single-item return (e.g. only one reminder) may decode as a plain string.
            ids.insert(s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s)
        }
        return ids
    }

    var isActivated: Bool {
        get async {
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        }
    }

    func activate() async throws {
        try await eventStore.requestFullAccessToReminders()
    }

    var tools: [Tool] {
        Tool(
            name: "reminders_lists",
            description: "List available reminder lists",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Reminder Lists",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let reminderLists = self.eventStore.calendars(for: .reminder)

            return reminderLists.map { reminderList in
                Value.object([
                    "title": .string(reminderList.title),
                    "source": .string(reminderList.source.title),
                    "color": .string(reminderList.color.accessibilityName),
                    "isEditable": .bool(reminderList.allowsContentModifications),
                    "isSubscribed": .bool(reminderList.isSubscribed),
                ])
            }
        }

        Tool(
            name: "reminders_fetch",
            description: """
                Get reminders from the reminders app with flexible filtering options.

                Each result may include:
                  - 'isSubtask' (boolean): true if the reminder is indented as a subtask of another, false if top-level.
                  - 'parentId' (string): the '@id' of the parent reminder, when isSubtask is true.

                Both fields are derived by cross-referencing EventKit with Reminders.app via AppleScript. If Automation permission for Reminders has not been granted, the fields are omitted — treat that as "unknown" rather than assuming any duplicates are unrelated. parentId is reliable for single-level nesting; deeply nested subtasks (subtasks of subtasks) may attribute the wrong parent.
                """,
            inputSchema: .object(
                properties: [
                    "completed": .boolean(
                        description:
                            "If true, fetch completed reminders; if false, fetch incomplete; if omitted, fetch all"
                    ),
                    "start": .string(
                        description:
                            "Start date/time range for fetching reminders. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time range for fetching reminders. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "lists": .array(
                        description:
                            "Names of reminder lists to fetch from; if empty, fetches from all lists",
                        items: .string()
                    ),
                    "query": .string(
                        description: "Text to search for in reminder titles"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Reminders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            // Filter reminder lists based on provided names
            var reminderLists = self.eventStore.calendars(for: .reminder)
            if case .array(let listNames) = arguments["lists"],
                !listNames.isEmpty
            {
                let requestedNames = Set(
                    listNames.compactMap { $0.stringValue?.lowercased() }
                )
                reminderLists = reminderLists.filter {
                    requestedNames.contains($0.title.lowercased())
                }
            }

            // Parse dates if provided
            var startDate: Date? = nil
            var endDate: Date? = nil
            var startIsDateOnly = false
            var endIsDateOnly = false

            if case .string(let start) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: start
                )
            {
                startDate = parsedStart.date
                startIsDateOnly = parsedStart.isDateOnly
            }
            if case .string(let end) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: end
                )
            {
                endDate = parsedEnd.date
                endIsDateOnly = parsedEnd.isDateOnly
            }

            let calendar = Calendar.current
            if let startDateValue = startDate {
                startDate = calendar.normalizedStartDate(
                    from: startDateValue,
                    isDateOnly: startIsDateOnly
                )
            }
            if let endDateValue = endDate {
                endDate = calendar.normalizedEndDate(from: endDateValue, isDateOnly: endIsDateOnly)
            }

            // Create predicate based on completion status
            let predicate: NSPredicate
            if case .bool(let completed) = arguments["completed"] {
                if completed {
                    predicate = self.eventStore.predicateForCompletedReminders(
                        withCompletionDateStarting: startDate,
                        ending: endDate,
                        calendars: reminderLists
                    )
                } else {
                    predicate = self.eventStore.predicateForIncompleteReminders(
                        withDueDateStarting: startDate,
                        ending: endDate,
                        calendars: reminderLists
                    )
                }
            } else {
                // If completion status not specified, use incomplete predicate as default
                predicate = self.eventStore.predicateForReminders(in: reminderLists)
            }

            // Fetch reminders
            let reminders = try await withCheckedThrowingContinuation { continuation in
                self.eventStore.fetchReminders(matching: predicate) { fetchedReminders in
                    continuation.resume(returning: fetchedReminders ?? [])
                }
            }

            // Apply additional filters
            var filteredReminders = reminders

            // Filter by search text if provided
            if case .string(let searchText) = arguments["query"],
                !searchText.isEmpty
            {
                filteredReminders = filteredReminders.filter {
                    $0.title?.localizedCaseInsensitiveContains(searchText) == true
                }
            }

            // Determine the visible (top-level) set per the Reminders app, so we
            // can tag each EventKit result as a subtask or not. If AppleScript
            // fails (permission denied / unavailable) we omit the flag rather
            // than guess.
            let topLevelIds = self.topLevelReminderIdentifiers(in: reminderLists)

            // EventKit returns reminders in Reminders.app display order: each
            // parent is followed immediately by its subtasks. Walk the ordered
            // results and attribute each subtask to the most recent top-level
            // row that preceded it. This is reliable for single-level nesting;
            // deeper nesting would need a per-row container lookup.
            var parentByChildId: [String: String] = [:]
            if let topLevelIds {
                var currentParentId: String?
                for r in filteredReminders {
                    if topLevelIds.contains(r.calendarItemIdentifier) {
                        currentParentId = r.calendarItemIdentifier
                    } else if let currentParentId {
                        parentByChildId[r.calendarItemIdentifier] = currentParentId
                    }
                }
            }

            return filteredReminders.map { reminder -> ReminderResult in
                var action = PlanAction(reminder)
                action.identifier = reminder.calendarItemIdentifier
                let isSubtask: Bool? = topLevelIds.map {
                    !$0.contains(reminder.calendarItemIdentifier)
                }
                let parentId = parentByChildId[reminder.calendarItemIdentifier]
                return ReminderResult(action: action, isSubtask: isSubtask, parentId: parentId)
            }
        }

        Tool(
            name: "reminders_create",
            description: """
                Create a new reminder with the specified properties.

                Subtasks: EventKit does not expose a public API for parent/child reminders, so this tool cannot nest reminders directly. Workaround: to create a reminder with N subtasks, call this tool N+1 times in order — first the parent, then each subtask as its own top-level reminder in the same list — and then tell the user to select the subtask rows in the Reminders app and indent them under the parent (right-arrow, or drag right). State this expectation clearly in your reply to the user.

                Note: once the user indents subtasks, subsequent reminders_fetch calls will only return the parent — EventKit hides indented subtasks from API results. They still exist in the Reminders app; do not report them as missing or deleted.
                """,
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "due": .string(
                        description:
                            "Due date/time for the reminder. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "list": .string(
                        description: "Reminder list name (uses default if not specified)"
                    ),
                    "notes": .string(),
                    "priority": .string(
                        default: .string(EKReminderPriority.none.stringValue),
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: "Minutes before due date to set alarms",
                        items: .integer()
                    ),
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let reminder = EKReminder(eventStore: self.eventStore)

            // Set required properties
            guard case .string(let title) = arguments["title"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder title is required"]
                )
            }
            reminder.title = title

            // Set calendar (list)
            var calendar = self.eventStore.defaultCalendarForNewReminders()
            if case .string(let listName) = arguments["list"] {
                if let matchingCalendar = self.eventStore.calendars(for: .reminder)
                    .first(where: { $0.title.lowercased() == listName.lowercased() })
                {
                    calendar = matchingCalendar
                }
            }
            reminder.calendar = calendar

            // Set optional properties
            if case .string(let dueDateStr) = arguments["due"],
                let parsedDueDate = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: dueDateStr
                )
            {
                let calendar = Calendar.current
                let dueDate = calendar.normalizedStartDate(
                    from: parsedDueDate.date,
                    isDateOnly: parsedDueDate.isDateOnly
                )
                reminder.dueDateComponents = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
            }

            if case .string(let notes) = arguments["notes"] {
                reminder.notes = notes
            }

            if case .string(let priorityStr) = arguments["priority"] {
                reminder.priority = Int(EKReminderPriority.from(string: priorityStr).rawValue)
            }

            // Set alarms
            if case .array(let alarmMinutes) = arguments["alarms"] {
                reminder.alarms = alarmMinutes.compactMap {
                    guard case .int(let minutes) = $0 else { return nil }
                    return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }
            }

            // Save the reminder
            try self.eventStore.save(reminder, commit: true)

            var action = PlanAction(reminder)
            action.identifier = reminder.calendarItemIdentifier
            return action
        }

        Tool(
            name: "reminders_delete",
            description:
                "Delete a reminder by its identifier. Use the '@id' value returned by reminders_fetch or reminders_create.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description:
                            "Identifier of the reminder to delete."
                    )
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case .string(let id) = arguments["id"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder id is required"]
                )
            }

            guard
                let reminder = self.eventStore.calendarItem(withIdentifier: id) as? EKReminder
            else {
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "No reminder found with id '\(id)'"]
                )
            }

            var action = PlanAction(reminder)
            action.identifier = reminder.calendarItemIdentifier

            try self.eventStore.remove(reminder, commit: true)

            return action
        }

        Tool(
            name: "reminders_mark_completed",
            description:
                "Mark a reminder as completed. Use the '@id' value returned by reminders_fetch or reminders_create. EventKit automatically records the current time as the completion date.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Identifier of the reminder to mark completed."
                    )
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Mark Reminder Completed",
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case .string(let id) = arguments["id"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder id is required"]
                )
            }

            guard
                let reminder = self.eventStore.calendarItem(withIdentifier: id) as? EKReminder
            else {
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "No reminder found with id '\(id)'"]
                )
            }

            reminder.isCompleted = true
            try self.eventStore.save(reminder, commit: true)

            var action = PlanAction(reminder)
            action.identifier = reminder.calendarItemIdentifier
            return action
        }
    }
}
