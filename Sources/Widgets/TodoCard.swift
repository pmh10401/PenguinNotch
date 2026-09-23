import SwiftUI

struct TodoItem: Codable, Equatable, Identifiable {
    var id = UUID()
    let title: String
    let createdAt: Date
    var completedAt: Date?

    static func today(_ items: [Self], now: Date, calendar: Calendar = .autoupdatingCurrent) -> [Self] {
        items.filter { $0.completedAt == nil } + items.filter {
            $0.completedAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false
        }
    }

    static func snapshot(_ items: [Self], now: Date = Date()) -> ProviderSnapshot {
        let items = today(items, now: now)
        let done = items.filter { $0.completedAt != nil }.count
        return ProviderSnapshot(id: "widget-todo", displayName: "TODO", glyph: .todo, fidelity: .official,
                                status: .ok,
                                windows: [LimitWindow(id: "today", label: L10n.t("Today's to-do"),
                                                      usedFraction: items.isEmpty ? 0 : Double(done) / Double(items.count),
                                                      usedText: "\(done)/\(items.count)",
                                                      bandOverride: .ample, prefersUsedText: true)], kind: .todo)
    }
}

extension Preferences {
    @discardableResult
    func addTodo(_ title: String, now: Date = Date()) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else { return false }
        todoItems.append(TodoItem(title: title, createdAt: now))
        return true
    }

    func toggleTodo(_ id: UUID, now: Date = Date()) {
        guard let index = todoItems.firstIndex(where: { $0.id == id }) else { return }
        todoItems[index].completedAt = todoItems[index].completedAt == nil ? now : nil
    }

    func removeTodo(_ id: UUID) { todoItems.removeAll { $0.id == id } }

    func promptForTodo() {
        // The hover panel deliberately never takes keyboard focus. Use a native
        // input dialog only after Add is clicked, keeping ordinary hovers passive.
        let alert = NSAlert()
        alert.messageText = L10n.t("Add a to-do")
        alert.informativeText = L10n.t("Up to 200 characters. Unfinished items carry over to the next day.")
        let add = alert.addButton(withTitle: L10n.t("Add"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = L10n.t("What would you like to do?")
        field.setAccessibilityLabel(L10n.t("To-do title"))
        alert.accessoryView = field
        add.isEnabled = false
        let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification,
                                                               object: field, queue: .main) { _ in
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            add.isEnabled = !title.isEmpty && title.count <= 200
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { addTodo(field.stringValue) }
    }
}

struct TodoCard: View {
    @ObservedObject var preferences: Preferences
    let now: Date
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    var color: Color?
    @Environment(\.penguinnotchAccentColor) private var accent
    @Environment(\.tooltipSecondaryInk) private var secondaryInk
    @State private var deleted: TodoItem?

    var body: some View {
        let items = TodoItem.today(preferences.todoItems, now: now)
        let done = items.filter { $0.completedAt != nil }.count
        TooltipShell(height: NotchLayout.todoCardHeight, direction: direction, tailOffset: tailOffset) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.t("Today's to-do")).font(Typography.cardTitle)
                    Spacer(minLength: 4)
                    Text("\(done)/\(items.count)").font(Typography.cardBody).foregroundStyle(secondaryInk)
                }
                Text(now.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11)).foregroundStyle(secondaryInk)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if items.isEmpty {
                            Text(L10n.t("Add your first task for today."))
                                .font(Typography.cardBody).foregroundStyle(secondaryInk)
                        }
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Button { preferences.toggleTodo(item.id) } label: {
                                    Image(systemName: item.completedAt == nil ? "circle" : "checkmark.circle.fill")
                                        .font(.system(size: 16)).foregroundStyle(color ?? accent)
                                }
                                .accessibilityLabel(item.completedAt == nil
                                    ? L10n.t("Complete \(item.title)") : L10n.t("Reopen \(item.title)"))
                                Text(item.title).font(Typography.cardBody)
                                    .strikethrough(item.completedAt != nil)
                                    .foregroundStyle(item.completedAt == nil ? Palette.textPrimary : secondaryInk)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button { deleted = item; preferences.removeTodo(item.id) } label: {
                                    Image(systemName: "trash").foregroundStyle(secondaryInk)
                                }
                                .accessibilityLabel(L10n.t("Delete \(item.title)"))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button { preferences.promptForTodo() } label: {
                        Label(L10n.t("Add to-do"), systemImage: "plus.circle")
                    }
                    Spacer(minLength: 4)
                    if let deleted {
                        Button(L10n.t("Undo delete")) {
                            if !preferences.todoItems.contains(where: { $0.id == deleted.id }) {
                                preferences.todoItems.append(deleted)
                            }
                            self.deleted = nil
                        }
                    }
                }
                .font(.system(size: 11)).foregroundStyle(color ?? accent)
                Text(L10n.t("Unfinished tasks carry over · Saved on this Mac"))
                    .font(.system(size: 9)).foregroundStyle(secondaryInk)
                    .lineLimit(2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textPrimary)
        }
    }
}
