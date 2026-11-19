/// A dictionary that enumerates its entries in the order C#'s `Dictionary` does: insertion order,
/// except that an entry added after a removal takes the most recently freed place. Ported C# code
/// that enumerates a dictionary uses this type, so it visits entries in the same order.
struct OrderedDictionary<Key: Hashable, Value>: Sequence {
    private var entries: [(key: Key, value: Value)?] = []
    private var slots: [Key: Int] = [:]
    private var free: [Int] = []

    init() {}

    init<S: Sequence>(_ elements: S) where S.Element == (Key, Value) {
        for (key, value) in elements {
            self[key] = value
        }
    }

    var count: Int { slots.count }

    var isEmpty: Bool { slots.isEmpty }

    var keys: [Key] { entries.compactMap { $0?.key } }

    var values: [Value] { entries.compactMap { $0?.value } }

    subscript(key: Key) -> Value? {
        get { slots[key].map { entries[$0]!.value } }
        set {
            if let newValue {
                if let slot = slots[key] {
                    entries[slot]!.value = newValue
                } else if let slot = free.popLast() {
                    entries[slot] = (key, newValue)
                    slots[key] = slot
                } else {
                    slots[key] = entries.count
                    entries.append((key, newValue))
                }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    func contains(key: Key) -> Bool { slots[key] != nil }

    /// Adds the entry unless the key is present, like C#'s `TryAdd`; returns whether it was added.
    @discardableResult
    mutating func tryAdd(_ key: Key, _ value: Value) -> Bool {
        guard slots[key] == nil else {
            return false
        }

        self[key] = value
        return true
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let slot = slots.removeValue(forKey: key) else {
            return nil
        }

        let value = entries[slot]!.value
        entries[slot] = nil
        free.append(slot)
        return value
    }

    mutating func removeAll() {
        entries = []
        slots = [:]
        free = []
    }

    func makeIterator() -> AnyIterator<(key: Key, value: Value)> {
        var iterator = entries.makeIterator()
        return AnyIterator {
            while let entry = iterator.next() {
                if let entry {
                    return entry
                }
            }

            return nil
        }
    }
}

/// A set that enumerates its elements in the order C#'s `HashSet` does (see `OrderedDictionary`).
struct OrderedSet<Element: Hashable>: Sequence {
    private var storage = OrderedDictionary<Element, Void>()

    init() {}

    init<S: Sequence>(_ elements: S) where S.Element == Element {
        for element in elements {
            insert(element)
        }
    }

    var count: Int { storage.count }

    var isEmpty: Bool { storage.isEmpty }

    func contains(_ element: Element) -> Bool { storage.contains(key: element) }

    /// Adds the element unless present, like C#'s `HashSet.Add`; returns whether it was added.
    @discardableResult
    mutating func insert(_ element: Element) -> Bool { storage.tryAdd(element, ()) }

    @discardableResult
    mutating func remove(_ element: Element) -> Bool { storage.removeValue(forKey: element) != nil }

    func makeIterator() -> AnyIterator<Element> {
        let iterator = storage.makeIterator()
        return AnyIterator { iterator.next()?.key }
    }
}

extension Sequence {
    /// The elements sorted like LINQ's `OrderBy`: stably, so equal elements keep their order.
    func stableSorted(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows -> [Element] {
        try enumerated()
            .sorted { a, b in
                if try areInIncreasingOrder(a.element, b.element) {
                    return true
                }

                if try areInIncreasingOrder(b.element, a.element) {
                    return false
                }

                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// The elements without repeats, in the order of their first occurrence, like LINQ's `Distinct`.
    func distinctInOrder<Key: Hashable>(by key: (Element) throws -> Key) rethrows -> [Element] {
        var seen = Set<Key>()
        var result: [Element] = []
        for element in self {
            if seen.insert(try key(element)).inserted {
                result.append(element)
            }
        }

        return result
    }
}

extension Sequence where Element: Hashable {
    /// The elements without repeats, in the order of their first occurrence, like LINQ's `Distinct`.
    func distinctInOrder() -> [Element] { distinctInOrder { $0 } }
}
