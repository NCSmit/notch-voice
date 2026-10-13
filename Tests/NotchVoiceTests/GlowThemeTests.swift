import Testing
@testable import NotchVoice

struct GlowThemeTests {
    @Test(arguments: GlowTheme.allCases)
    func paletteLoopsWithoutASeam(theme: GlowTheme) {
        #expect(theme.colors.count >= 3)
        #expect(theme.colors.first == theme.colors.last)
    }

    @Test func themeNamesAreUnique() {
        #expect(Set(GlowTheme.allCases.map(\.name)).count == GlowTheme.allCases.count)
    }
}
