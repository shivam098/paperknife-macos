/// The C# names are the raw values, as C#'s `ToString()` gives them.
public enum EditStatus: String {
    case applied = "Applied"
    case noChange = "NoChange"
    case rejected = "Rejected"
}

/// The C# names are the raw values, as C#'s `ToString()` gives them.
public enum EditRejection: String {
    case none = "None"
    case invalidTarget = "InvalidTarget"
    case unsupportedCharacters = "UnsupportedCharacters"
    case editingRestricted = "EditingRestricted"
    case pageNotEditable = "PageNotEditable"
    case collateralChange = "CollateralChange"
    case engineError = "EngineError"
}

/// The outcome of an edit. A rejected edit leaves the document exactly as it was.
public final class EditResult {
    private init(
        _ status: EditStatus,
        _ rejection: EditRejection,
        _ message: String,
        _ warnings: [String],
        _ unsupportedCharacters: [String],
        _ textRun: PdfTextRun?,
        _ details: [String]? = nil
    ) {
        self.status = status
        self.rejection = rejection
        self.message = message
        self.warnings = warnings
        self.unsupportedCharacters = unsupportedCharacters
        self.textRun = textRun
        self.details = details ?? []
    }

    public let status: EditStatus

    public let rejection: EditRejection

    /// A user-facing explanation of what happened.
    public let message: String

    public let warnings: [String]

    /// For applied edits: more about what changed that isn't a warning, such as a font PaperKnife completed.
    public let details: [String]

    /// For `EditRejection.unsupportedCharacters`: the characters that can't be used.
    public let unsupportedCharacters: [String]

    /// For applied text edits: the edited run as it exists in the committed document; nil when the text was deleted.
    public let textRun: PdfTextRun?

    static func applied(_ message: String, _ warnings: [String]? = nil, _ textRun: PdfTextRun? = nil, _ details: [String]? = nil) -> EditResult {
        EditResult(.applied, EditRejection.none, message, warnings ?? [], [], textRun, details)
    }

    static func noChange(_ message: String) -> EditResult {
        EditResult(.noChange, EditRejection.none, message, [], [], nil)
    }

    static func rejected(_ rejection: EditRejection, _ message: String, _ unsupportedCharacters: [String]? = nil) -> EditResult {
        EditResult(.rejected, rejection, message, [], unsupportedCharacters ?? [], nil)
    }
}
