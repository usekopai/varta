import AppKit
import SwiftUI
import VartaCore

@MainActor final class CalendarAgendaWindow: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Varta — Calendar"
        window.minSize = NSSize(width: 400, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(_ agenda: CalendarAgenda) {
        window?.contentView = NSHostingView(rootView: AgendaView(agenda: agenda))
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
private struct AgendaView: View {
    let agenda: CalendarAgenda
    private func date(_ value: Date, timeOnly: Bool = false) -> String {
        let f = DateFormatter(); f.timeZone = agenda.timeZone
        f.dateStyle = timeOnly ? .none : .full; f.timeStyle = timeOnly ? .short : .none
        return f.string(from: value)
    }
    private func interval(_ entry: CalendarEntry) -> String {
        if entry.allDay { return "All day" }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = agenda.timeZone
        let f = DateFormatter(); f.timeZone = agenda.timeZone; f.timeStyle = .short
        f.dateStyle = calendar.isDate(entry.start, inSameDayAs: entry.end) ? .none : .short
        return f.string(from: entry.start) + " – " + f.string(from: entry.end)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(date(agenda.day)).font(.title2.bold())
            Text("\(agenda.total) events · \(agenda.timeZone.identifier)").foregroundStyle(.secondary)
            Divider()
            if agenda.entries.isEmpty {
                ContentUnavailableView("No events", systemImage: "calendar", description: Text("There are no calendar events for this day."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(agenda.entries.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.title).font(.headline).textSelection(.enabled)
                                Text(interval(entry)).font(.subheadline)
                                Text(entry.calendarName).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                        if agenda.total > agenda.entries.count {
                            Text("Showing the first \(agenda.entries.count) events. Open Calendar for the full day.").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
