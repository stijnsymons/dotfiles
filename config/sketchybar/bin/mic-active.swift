// Prints 1 if any process is currently capturing audio input, else 0.
// This is the same signal the macOS orange mic indicator reads.
//
// It asks the PROCESS list, not the devices: a device is "running somewhere"
// as soon as any of its streams is live, so a duplex device (AirPods, most USB
// headsets) that is merely PLAYING flagged the mic as in use and pinned the
// red indicator on for the whole time you wore headphones.
//
// kAudioHardwarePropertyProcessObjectList is macOS 14.2+; if it is missing at
// runtime this falls back to the old device walk rather than reporting nothing.
// Build: swiftc -O -o bin/mic-active bin/mic-active.swift
import CoreAudio

let system = AudioObjectID(kAudioObjectSystemObject)

// nil = the property is not available here (use the fallback); [] = no processes.
func processObjects() -> [AudioObjectID]? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(system, &addr) else { return nil }
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
    guard size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
    return ids
}

func isRunningInput(_ id: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr else { return false }
    return running != 0
}

// --- fallback: the pre-14.2 device walk ------------------------------------
func devices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func hasInput(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return false }
    let list = buf.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
}

func isCapturing(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr else { return false }
    return running != 0
}

if let procs = processObjects() {
    print(procs.contains { isRunningInput($0) } ? 1 : 0)
} else {
    print(devices().contains { hasInput($0) && isCapturing($0) } ? 1 : 0)
}
