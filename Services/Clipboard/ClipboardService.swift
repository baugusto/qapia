import Foundation

#if os(macOS)
import AppKit
#endif

public protocol ClipboardService: AnyObject {
    func copy(_ value: String)
}

public final class PasteboardClipboardService: ClipboardService {
    public init() {}

    public func copy(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}

public final class MemoryClipboardService: ClipboardService {
    public private(set) var lastCopiedValue: String?

    public init() {}

    public func copy(_ value: String) {
        lastCopiedValue = value
    }
}
