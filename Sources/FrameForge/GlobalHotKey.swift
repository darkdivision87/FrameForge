import Carbon
import Foundation

final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var legacyHotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var isRegistered = false
    private let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _,event,context in
            guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&identifier)
            guard identifier.signature == 0x46464745, (identifier.id == 1 || identifier.id == 2) else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
        let id = EventHotKeyID(signature:0x46464745,id:1)
        isRegistered = RegisterEventHotKey(UInt32(kVK_ANSI_R),UInt32(optionKey|shiftKey),id,GetApplicationEventTarget(),0,&hotKey) == noErr
        let legacyID = EventHotKeyID(signature:0x46464745,id:2)
        RegisterEventHotKey(UInt32(kVK_ANSI_R),UInt32(cmdKey|controlKey),legacyID,GetApplicationEventTarget(),0,&legacyHotKey)
    }
    deinit { if let legacyHotKey = legacyHotKey { UnregisterEventHotKey(legacyHotKey) }; if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }; if let handler = handler { RemoveEventHandler(handler) } }
}
