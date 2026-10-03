import SwiftUI

struct RecentOpenMenu: View {
    @ObservedObject var history: RecentOpenHistory
    let open: ([URL]) -> Void
    var compact = false

    var body: some View {
        Menu {
            if history.entries.isEmpty {
                Text("No Recent Files or Folders")
            } else {
                ForEach(history.entries) { entry in
                    Button {
                        open(entry.urls)
                    } label: {
                        Text(entry.displayName)
                        Text(entry.pathDescription)
                    }
                    .help(entry.pathDescription)
                }
                Divider()
                Button("Clear Recent History") {
                    history.clear()
                    NSDocumentController.shared.clearRecentDocuments(nil)
                }
            }
        } label: {
            if compact {
                Image(systemName: "clock.arrow.circlepath")
            } else {
                Text("Open Recent")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Open Recent Files or Folders")
    }
}
