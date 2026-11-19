import Foundation

/// C#'s `Exception`: the base of the errors the engine throws where the C# engine throws an
/// exception, so callers catch the same failures and show the same messages. The hierarchy
/// follows C#'s, so `error is ArgumentException` also matches an `ArgumentOutOfRangeException`.
public class DotNetException: Error, LocalizedError, CustomStringConvertible, @unchecked Sendable {
    private let text: String

    public init(_ message: String) {
        text = message
    }

    /// C#'s `Message`.
    public var message: String { text }

    public var errorDescription: String? { message }

    public var description: String { "\(type(of: self)): \(message)" }
}

/// C#'s `ArgumentException`: an argument a caller passed isn't valid.
public class ArgumentException: DotNetException, @unchecked Sendable {
    /// C#'s `ParamName`.
    public let paramName: String?

    public init(_ message: String, _ paramName: String? = nil) {
        self.paramName = paramName
        super.init(message)
    }

    /// The message followed by the parameter's name, as .NET writes it.
    public override var message: String {
        guard let paramName, !paramName.isEmpty else {
            return super.message
        }

        return "\(super.message) (Parameter '\(paramName)')"
    }

    /// `ArgumentException.ThrowIfNullOrEmpty(argument, paramName)` for a string that can't be null.
    static func throwIfNullOrEmpty(_ argument: String, _ paramName: String) throws {
        if argument.isEmpty {
            throw ArgumentException("The value cannot be an empty string.", paramName)
        }
    }
}

/// C#'s `ArgumentOutOfRangeException`: an argument is outside the range of valid values.
public final class ArgumentOutOfRangeException: ArgumentException, @unchecked Sendable {
    /// C#'s `ActualValue`, as .NET writes it in the message.
    public let actualValue: String?

    public init(
        _ paramName: String?,
        _ actualValue: String? = nil,
        _ message: String = "Specified argument was out of the range of valid values."
    ) {
        self.actualValue = actualValue
        super.init(message, paramName)
    }

    /// The message, the parameter's name and the actual value, as .NET writes them.
    public override var message: String {
        guard let actualValue else {
            return super.message
        }

        return "\(super.message)\nActual value was \(actualValue)."
    }

    /// `ArgumentOutOfRangeException.ThrowIfNegative(value, paramName)`.
    static func throwIfNegative(_ value: Int, _ paramName: String) throws {
        if value < 0 {
            throw ArgumentOutOfRangeException(paramName, String(value), "\(paramName) ('\(value)') must be a non-negative value.")
        }
    }

    /// `ArgumentOutOfRangeException.ThrowIfZero(value, paramName)`.
    static func throwIfZero(_ value: Int, _ paramName: String) throws {
        if value == 0 {
            throw ArgumentOutOfRangeException(paramName, String(value), "\(paramName) ('\(value)') must be a non-zero value.")
        }
    }

    /// `ArgumentOutOfRangeException.ThrowIfLessThan(value, other, paramName)`.
    static func throwIfLessThan(_ value: Int, _ other: Int, _ paramName: String) throws {
        if value < other {
            throw ArgumentOutOfRangeException(
                paramName, String(value), "\(paramName) ('\(value)') must be greater than or equal to '\(other)'.")
        }
    }

    /// `ArgumentOutOfRangeException.ThrowIfGreaterThan(value, other, paramName)`.
    static func throwIfGreaterThan(_ value: Int, _ other: Int, _ paramName: String) throws {
        if value > other {
            throw ArgumentOutOfRangeException(
                paramName, String(value), "\(paramName) ('\(value)') must be less than or equal to '\(other)'.")
        }
    }

    /// `ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(value, other, paramName)`.
    static func throwIfGreaterThanOrEqual(_ value: Int, _ other: Int, _ paramName: String) throws {
        if value >= other {
            throw ArgumentOutOfRangeException(paramName, String(value), "\(paramName) ('\(value)') must be less than '\(other)'.")
        }
    }
}

/// C#'s `InvalidOperationException`: a call isn't valid in the object's current state.
public class InvalidOperationException: DotNetException, @unchecked Sendable {
    public override init(_ message: String = "Operation is not valid due to the current state of the object.") {
        super.init(message)
    }
}

/// C#'s `ObjectDisposedException`: the object was disposed of (closed) before the call.
public final class ObjectDisposedException: InvalidOperationException, @unchecked Sendable {
    /// C#'s `ObjectName`.
    public let objectName: String?

    public init(objectName: String?) {
        self.objectName = objectName
        super.init("Cannot access a disposed object.")
    }

    /// The message followed by the object's name, as .NET writes it.
    public override var message: String {
        guard let objectName, !objectName.isEmpty else {
            return super.message
        }

        return "\(super.message)\nObject name: '\(objectName)'."
    }

    /// `ObjectDisposedException.ThrowIf(condition, instance)`, which names the instance's type as
    /// C# does: `PaperKnife.Core.PdfDocument` for a `PdfDocument`.
    static func throwIf(_ condition: Bool, _ instance: AnyObject) throws {
        if condition {
            throw ObjectDisposedException(objectName: dotNetName(of: instance))
        }
    }

    private static func dotNetName(of instance: AnyObject) -> String {
        let name = String(reflecting: type(of: instance))
        let module = "PaperKnifeCore."
        return name.ordinalHasPrefix(module) ? "PaperKnife.Core." + String(name.dropFirst(module.count)) : name
    }
}
