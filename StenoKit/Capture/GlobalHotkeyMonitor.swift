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
    // nonisolated(unsafe) because deinit is nonisolated in Swift 6. This is
    // safe: deinit is the only context where exclusive access is structurally
    // guaranteed — no other reference to the object survives.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?

    /// 'STNO' — identifies our hot key in the event, so the handler ignores
    /// anything else the dispatcher routes through it.
    private static let signature = OSType(0x5354_4E4F)

    public init() {}

    nonisolated private func cleanupCarbon() {
        // Tear down Carbon registrations; failures here are best-effort cleanup
        // and do not report errors, since this may be called from deinit.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        self.hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        self.handlerRef = nil
    }

    deinit {
        cleanupCarbon()
    }

    public func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws {
        // Idempotent: rebinding from M1-08 is register-over-register, and a
        // stale handler would deliver the old chord as well as the new one.
        unregister()
        self.onPress = onPress

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        // `passUnretained`: the context pointer is unretained. It's safe because
        // deinit unconditionally tears down the Carbon registration via
        // cleanupCarbon(), so the pointer cannot outlive the object.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }

                // The handler is installed on the *dispatcher* target, so every
                // hot key registered in this process arrives here. Check the
                // signature before acting, or a second hot key (M1-08's rebind,
                // or anything a later milestone adds) would fire this one's
                // action too. Unmatched events return `eventNotHandledErr` so
                // they continue on to whoever does own them.
                var hotKeyID = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard read == noErr,
                    hotKeyID.signature == CarbonHotkeyMonitor.signature
                else { return OSStatus(eventNotHandledErr) }

                let monitor = Unmanaged<CarbonHotkeyMonitor>.fromOpaque(userData)
                    .takeUnretainedValue()
                // Carbon dispatches hot keys on the main thread; this asserts
                // that rather than hopping, because a hop would put the panel
                // one runloop turn further from the keypress (§1.1).
                MainActor.assumeIsolated { monitor.onPress?() }
                return noErr
            }, 1, &spec, context, &handlerRef)

        guard handlerStatus == noErr else {
            unregister()
            throw HotkeyRegistrationError.systemRefused(handlerStatus)
        }

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
        cleanupCarbon()
        onPress = nil
    }
}
