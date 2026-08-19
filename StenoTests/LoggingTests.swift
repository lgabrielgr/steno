import Testing

@testable import StenoKit

@Test("os.Log subsystem matches the identifier fixed by §9.1")
func subsystemIsFixed() {
    #expect(Log.subsystem == "com.lgabrielgr.steno")
}
