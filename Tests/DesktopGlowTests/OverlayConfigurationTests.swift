import Testing
@testable import DesktopGlow

@Test
func opacityIsBoundedAndNonfiniteValuesAreRejected() {
    #expect(OverlayConfiguration(opacity: -1).normalized.opacity == 0)
    #expect(OverlayConfiguration(opacity: 2).normalized.opacity == 1)
    #expect(OverlayConfiguration(opacity: .nan).normalized.opacity == 1)
    #expect(OverlayConfiguration(opacity: 0.3).normalized.opacity == 0.3)
}
