import SwiftUI

/// 代替 `@State`：新版 SDK 把 `@State` 做成了宏，只装命令行工具时找不到宏插件，编译不过。
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var storage: State<Value>
    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }
    var wrappedValue: Value { get { storage.wrappedValue } nonmutating set { storage.wrappedValue = newValue } }
    var projectedValue: Binding<Value> { storage.projectedValue }
}
