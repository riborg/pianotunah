import Foundation
import PianoTunahCore

extension DecimalSeparator {
    /// The separator the locale writes numbers with.
    init(_ locale: Locale) {
        self = locale.decimalSeparator == "," ? .comma : .point
    }
}
