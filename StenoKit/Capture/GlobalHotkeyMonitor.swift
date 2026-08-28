import Carbon.HIToolbox
import Foundation

/// Why a chord could not be bound.
public enum HotkeyRegistrationError: Error, Equatable {
    /// `eventHotKeyExistsErr` — this process already holds the chord.
    case alreadyRegistered
    /// Any other non-`noErr` status from `RegisterEventHotKey`.
    case systemRefused(OSStatus)

    /// Written for a person, not a log: M1-08's rebinding pane shows this
    /// string verbatim.
    public var message: String {
        switch self {
        case .alreadyRegistered:
            return "That shortcut is already registered."
        case .systemRefused(let status):
            return "macOS refused the shortcut (error \(status))."
        }
    }
}

/// Binds a system-wide chord.
///
/// A protocol so `QuickCaptureModel` is testable without registering anything
/// real — ARCHITECTURE §2 rule 4, applied to a system service rather than a
/// network one.
@MainActor
public protocol GlobalHotkeyMonitor: AnyObject {
    func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws
    func unregister()
}

/// The real one, over Carbon's hot key API.
///
/// **`RegisterEventHotKey`, deliberately, and not an `NSEvent` global monitor
/// or a `CGEventTap`.** Those two are gated by Accessibility (TCC) and fail
/// silently until the user grants it; this one is dispatched by the
/// WindowServer to the registering process and needs no permission at all.
/// That is why M1-03 ships no permissions UI, and why REQUIREMENTS.md §9.3
/// was amended — see design §1. If a permission dialog ever appears for this
/// feature, that reasoning is wrong and should be revisited rather than
/// worked around.
@MainActor
public final class CarbonHotkeyMonitor: GlobalHotkeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?

    /// 'STNO' — identifies our hot key in the event, so the handler ignores
    /// anything else the dispatcher routes through it.
    private static let signature = OSType(0x5354_4E4F)

    public init() {}

    public func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws {
        // Idempotent: rebinding from M1-08 is register-over-register, and a
        // stale handler would deliver the old chord as well as the new one.
        unregister()
        self.onPress = onPress

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        // `passUnretained`: the handler is torn down in `unregister`, which
        // runs before deinit can complete, so retaining self here would be a
        // cycle for no added safety.
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let monitor = Unmanaged<CarbonHotkeyMonitor>.fromOpaque(userData)
                    .takeUnretainedValue()
                // Carbon dispatches hot keys on the main thread; this asserts
                // that rather than hopping, because a hop would put the panel
                // one runloop turn further from the keypress (§1.1).
                MainActor.assumeIsolated { monitor.onPress?() }
                return noErr
            }, 1, &spec, context, &handlerRef)

        let status = RegisterEventHotKey(
            UInt32(chord.keyCode), chord.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(), 0, &hotKeyRef)

        guard status == noErr else {
            unregister()
            throw status == OSStatus(eventHotKeyExistsErr)
                ? HotkeyRegistrationError.alreadyRegistered
                : HotkeyRegistrationError.systemRefused(status)
        }
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        onPress = nil
    }
}
