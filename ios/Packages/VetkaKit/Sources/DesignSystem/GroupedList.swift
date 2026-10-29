import SwiftUI

public extension View {
    /// A grouped list in the app's colors: rows on surface, the page on
    /// background, hairlines in border, in both themes.
    func groupedListStyle() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.vetkaBackground)
            .listRowBackground(Color.vetkaSurface)
            .environment(\.defaultMinListRowHeight, 48)
    }

    func groupedRow() -> some View {
        listRowBackground(Color.vetkaSurface)
            .listRowSeparatorTint(Color(uiColor: Palette.border))
    }
}
