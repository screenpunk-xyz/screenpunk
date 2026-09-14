import AppKit
import SwiftUI

struct ScreenIconSheet: View {
    @ObservedObject var model: MacWorkbenchModel
    var body: some View {
        SymbolPickerSheet(initialSymbol: model.selectedScreen.map { model.symbol(for: $0) } ?? "star",
                          onSave: { model.changeScreenIcon($0) }, onCancel: { model.sheet = nil })
    }
}

struct SymbolPickerSheet: View {
    let initialSymbol: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var query = ""
    @State private var selected = "star"
    private let columns = Array(repeating: GridItem(.fixed(52), spacing: 8), count: 7)
    private var results: [String] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "." })
        return ScreenSymbolCatalog.available.filter { symbol in terms.allSatisfy { symbol.contains($0) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Icon").font(.title2.bold())
            TextField("Find a symbol", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(results, id: \.self) { symbol in
                            Button { selected = symbol } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 23, weight: .regular))
                                    .frame(width: 52, height: 48)
                                    .foregroundStyle(selected == symbol ? Color.white : Color.primary)
                                    .background(selected == symbol ? WorkbenchPalette.accent : Color.clear, in: .rect(cornerRadius: 10))
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(symbol).accessibilityLabel(symbol)
                            .accessibilityAddTraits(selected == symbol ? .isSelected : [])
                        }
                    }
                }
            }.frame(height: 300).id(query)
            Text("\(results.count) symbols").font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(selected, systemImage: selected).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(selected) }
                    .keyboardShortcut(.defaultAction).workbenchButton(prominent: true)
            }
        }
        .padding(24).frame(width: 468)
        .onAppear { selected = initialSymbol }
    }
}
