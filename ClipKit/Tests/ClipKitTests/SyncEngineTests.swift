import Testing
@testable import ClipKit

@Test func parsesPhotoEventFiles() {
    let serial = "0123456789abcdef0123456789abcdef"
    for ext in ["jpg", "meta.json", "meta.snap", "boot", "time.json"] {
        let parsed = SyncEngine.parseEventFileName("event_240126_084935_\(serial).\(ext)")
        #expect(parsed?.event == "event_240126_084935_\(serial)")
        #expect(parsed?.datePath == "2024/01/26")
    }
}

@Test func rejectsNonEventFiles() {
    #expect(SyncEngine.parseEventFileName("cid") == nil)
    #expect(SyncEngine.parseEventFileName("upgrade_log_141226_150046.txt") == nil)
    #expect(SyncEngine.parseEventFileName("event_240126_084935_tooshort.jpg") == nil)
}
