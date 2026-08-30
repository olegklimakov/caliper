import Foundation
import IOKit

/// Small helpers over the IORegistry C API, so samplers deal in Swift values
/// and never in retain counts.
enum IORegistry {
    /// Calls `body` for every service of the given class, releasing each entry
    /// afterwards.
    static func forEachService(matching className: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching(className),
                &iterator
            ) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    /// Runs `body` against the entry's parent in the service plane.
    static func withParent<T>(_ entry: io_registry_entry_t, _ body: (io_registry_entry_t) -> T?) -> T? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
            parent != 0
        else { return nil }
        defer { IOObjectRelease(parent) }
        return body(parent)
    }

    /// Calls `body` for every descendant of `entry` in the service plane,
    /// releasing each afterwards. Returns false when the registry changed
    /// mid-walk and the iteration is incomplete — the caller must not act on
    /// what it saw, or entries the walk never reached read as gone.
    @discardableResult
    static func forEachChild(
        of entry: io_registry_entry_t,
        _ body: (io_registry_entry_t) -> Void
    ) -> Bool {
        var iterator: io_iterator_t = 0
        guard
            IORegistryEntryCreateIterator(
                entry,
                kIOServicePlane,
                IOOptionBits(kIORegistryIterateRecursively),
                &iterator
            ) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            body(child)
            IOObjectRelease(child)
        }
        return IOIteratorIsValid(iterator) != 0
    }

    /// The entry's IOKit class name.
    static func className(_ entry: io_registry_entry_t) -> String? {
        IOObjectCopyClass(entry)?.takeRetainedValue() as String?
    }

    static func entryID(_ entry: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS ? id : nil
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    /// IORegistry strings arrive either as `CFString` or as NUL-padded `CFData`.
    static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        switch property(entry, key) {
        case let data as Data: String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        case let string as String: string
        default: nil
        }
    }

    static func integer(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    static func dictionary(_ entry: io_registry_entry_t, _ key: String) -> [String: Any]? {
        property(entry, key) as? [String: Any]
    }

    static func dictionaries(_ entry: io_registry_entry_t, _ key: String) -> [[String: Any]]? {
        property(entry, key) as? [[String: Any]]
    }
}
