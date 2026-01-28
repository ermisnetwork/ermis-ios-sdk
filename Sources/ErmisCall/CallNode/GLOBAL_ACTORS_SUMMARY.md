# Global Actor Implementation Summary

## Overview
We've implemented custom global actors to ensure thread-safe execution of critical call operations. This provides better safety guarantees and makes the code easier to reason about.

## Global Actors Created

### 1. **CallStateActor** (`@CallStateActor`)
**Purpose:** Manages all call state transitions
**Use for:**
- `Call.setState(_:)` - Ensures state changes happen serially
- Any code that modifies call state
- State transition logic

**Benefits:**
- All state transitions are serialized (no race conditions)
- Predictable state flow
- Easier debugging of state-related issues

### 2. **CallKitActor** (`@CallKitActor`)
**Purpose:** Manages all CallKit-related operations
**Use for:**
- Reporting calls to CallKit (`reportIncommingCall`, `reportOutgoingCallStarted`, etc.)
- CallKit updates (`reportUpdateCall`, `reportOutgoingCallConnected`)
- CXProviderDelegate methods (all `provider(_:perform:)` methods)
- CXCallObserver callbacks

**Benefits:**
- CallKit operations are properly serialized
- No concurrent CallKit API calls
- Prevents CallKit transaction conflicts

### 3. **CallNodeActor** (`@CallNodeActor`)
**Purpose:** Manages WebRTC/CallNode operations
**Use for:**
- Media operations (future use)
- Connection state management (future use)
- Audio/Video stream handling (future use)

**Benefits:**
- Media operations are isolated from UI
- Proper synchronization of WebRTC state

## Updated Files

### CallGlobalActors.swift (NEW)
```swift
@globalActor
public actor CallStateActor {
    public static let shared = CallStateActor()
}

@globalActor
public actor CallKitActor {
    public static let shared = CallKitActor()
}

@globalActor
public actor CallNodeActor {
    public static let shared = CallNodeActor()
}
```

### Call.swift
**Changes:**
- `setState(_:)` annotated with `@CallStateActor`
- Ensures all state transitions happen on the CallStateActor
- Fixed CallKit reporting to use `@CallKitActor` in tasks

### CallManager.swift
**Changes:**
All CallKit-related methods now use `@CallKitActor`:
- `reportIncommingCall(_:completion:)`
- `reportOutgoingCallStarted(_:)`
- `reportUpdateCall(for:localizedCallName:hasVideo:)`
- `reportOutgoingCallStartConnecting(_:)`
- `reportOutgoingCallConnected(uuid:connectedAt:)`
- `reportCallEnded(_:reason:)`
- All `CXProviderDelegate` methods:
  - `providerDidBegin(_:)`
  - `providerDidReset(_:)`
  - `provider(_:perform:)` (all variants)
  - `provider(_:didActivate:)`
  - `provider(_:didDeactivate:)`
  - `provider(_:timedOutPerforming:)`

## Usage Guidelines

### When to use `@CallStateActor`:
```swift
@CallStateActor
func updateCallState() {
    // This code runs on CallStateActor
    await call.setState(.connected)
}
```

### When to use `@CallKitActor`:
```swift
@CallKitActor
func reportToCallKit() {
    // This code runs on CallKitActor
    callProvider.reportCall(with: uuid, updated: update)
}
```

### Crossing Actor Boundaries:
```swift
func someMethod() {
    Task { @CallStateActor in
        // State operations
        await call.setState(.ringing)
        
        // Need to report to CallKit? Switch actors:
        Task { @CallKitActor in
            CallManager.shared.reportUpdateCall(for: uuid)
        }
    }
}
```

## Benefits

1. **Type Safety:** Compiler enforces proper actor usage
2. **No Data Races:** Actor isolation prevents concurrent access
3. **Clear Ownership:** Each domain has a clear executor
4. **Better Performance:** Reduces unnecessary synchronization
5. **Easier Debugging:** Know exactly which actor a method runs on
6. **Future Proof:** Easy to add more domain-specific actors

## Migration Notes

### For Call State Changes:
```swift
// Before:
call.setState(.connected)

// After:
await call.setState(.connected)  // Already on CallStateActor
// OR
Task { @CallStateActor in
    await call.setState(.connected)
}
```

### For CallKit Operations:
```swift
// Before:
CallManager.shared.reportOutgoingCallStarted(call)

// After:
Task { @CallKitActor in
    try await CallManager.shared.reportOutgoingCallStarted(call)
}
```

## Testing Considerations

- Unit tests should create tasks on the appropriate actor
- Mock actors for testing if needed
- Use `@CallStateActor` or `@CallKitActor` annotations in test methods

## Next Steps

1. Consider adding more specific actors for:
   - Audio management (`@AudioActor`)
   - Video management (`@VideoActor`)
   - Network operations (`@NetworkActor`)

2. Move more CallNodeClient operations to `@CallNodeActor`

3. Add actor-based logging to track actor switching

## Common Patterns

### Pattern 1: State Change → CallKit Report
```swift
@CallStateActor
func handleCallConnected() async {
    await call.setState(.connected)
    
    Task { @CallKitActor in
        CallManager.shared.reportOutgoingCallConnected(
            uuid: await call.uuid,
            connectedAt: Date()
        )
    }
}
```

### Pattern 2: CallKit Callback → State Update
```swift
@CallKitActor
public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    Task { @MainActor in
        guard let currentCall = await state.currentCall else { return }
        
        Task { @CallStateActor in
            await currentCall.setState(.connecting)
        }
    }
}
```

### Pattern 3: Multiple Actor Coordination
```swift
func complexOperation() {
    Task { @MainActor in
        // Update UI
        showConnecting()
        
        Task { @CallStateActor in
            // Update state
            await call.setState(.connecting)
            
            Task { @CallKitActor in
                // Report to CallKit
                CallManager.shared.reportUpdateCall(for: uuid)
            }
        }
    }
}
```
