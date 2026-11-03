import Foundation
import Savings

/// The receiving module owns the migrated business authority. Never read the retired source at runtime.
enum MonthlySource {
    static func confirmedPayments() throws -> Data {
        try SavingsModuleRuntime.integratedMonthlyPayments()
    }
}
