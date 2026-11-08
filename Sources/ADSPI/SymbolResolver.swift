import Darwin
import ObjectiveC

/// Looks up private symbols and classes at run time. Nothing here instantiates a class or
/// runs its `+initialize`, so it is safe in the launch-time probe.
enum SymbolResolver {
    /// The symbol from the first of `paths` that loads and exports it, or nil if none does.
    static func symbol(_ name: String, in paths: [String]) -> UnsafeMutableRawPointer? {
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            if let symbol = dlsym(handle, name) { return symbol }
        }
        return nil
    }

    /// True if an already loaded image exports the symbol. A weak import that this returns
    /// false for is a null function, and calling it would crash.
    static func isLoaded(_ name: String) -> Bool {
        // RTLD_DEFAULT from <dlfcn.h>. Swift can't import that macro because it is a cast.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }

    /// The named Objective-C class, or nil if no loaded image defines it.
    static func objcClass(_ name: String) -> AnyClass? {
        objc_lookUpClass(name)
    }

    /// True if instances of `objcClass` have the method, inherited ones included.
    static func hasInstanceMethod(_ selector: String, on objcClass: AnyClass) -> Bool {
        class_getInstanceMethod(objcClass, Selector(selector)) != nil
    }
}
