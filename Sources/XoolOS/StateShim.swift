import SwiftUI

// SwiftUI's `@State` is a macro in the macOS 27 SDK, and its plugin
// (SwiftUIMacros) ships with Xcode only. Built with the command-line tools
// alone, `@State` does not compile. `@XState` is the same storage without the
// macro, so the app builds with either toolchain.
@propertyWrapper
struct XState<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) { storage = SwiftUI.State<Value>(wrappedValue: wrappedValue) }
    init(initialValue: Value) { storage = SwiftUI.State<Value>(wrappedValue: initialValue) }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { storage.projectedValue }
}
