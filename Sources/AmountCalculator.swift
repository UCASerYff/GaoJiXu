import Foundation
import SwiftUI

/// Decimal arithmetic with multiplication/division before addition/subtraction.
enum AmountCalculation {
    static func evaluate(_ expression: String) -> Double? {
        let input = expression.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
        guard !input.isEmpty, input.count <= 120 else { return nil }
        let chars = Array(input)
        var index = 0
        func number() -> Decimal? {
            let start = index
            if index < chars.count && (chars[index] == "-" || chars[index] == "+") { index += 1 }
            var digits = 0, dots = 0
            while index < chars.count {
                let ch = chars[index]
                if ch >= "0" && ch <= "9" { digits += 1 }
                else if ch == "." { dots += 1 }
                else { break }
                index += 1
            }
            guard digits > 0, digits <= 16, dots <= 1 else { return nil }
            return Decimal(string: String(chars[start..<index]), locale: Locale(identifier: "en_US_POSIX"))
        }
        func term() -> Decimal? {
            guard var value = number() else { return nil }
            while index < chars.count && (chars[index] == "*" || chars[index] == "/") {
                let op = chars[index]; index += 1
                guard let rhs = number(), !(op == "/" && rhs == 0) else { return nil }
                value = op == "*" ? value * rhs : value / rhs
                guard !value.isNaN else { return nil }
            }
            return value
        }
        guard var value = term() else { return nil }
        while index < chars.count {
            let op = chars[index]
            guard op == "+" || op == "-" else { return nil }
            index += 1
            guard let rhs = term() else { return nil }
            value = op == "+" ? value + rhs : value - rhs
        }
        guard !value.isNaN else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        let result = NSDecimalNumber(decimal: rounded).doubleValue
        return result.isFinite && abs(result) <= 999_999_999_999.99 ? result : nil
    }
}

struct AmountCalculatorView: View {
    @Binding var expression: String
    let currency: String
    @State private var didEvaluate = false
    private let keys = ["C", "⌫", "%", "÷", "7", "8", "9", "×", "4", "5", "6", "−", "1", "2", "3", "+", "00", "0", ".", "="]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("金额（\(currency)）· 可输入算式", text: $expression)
                .font(.title3.monospacedDigit()).textFieldStyle(.roundedBorder)
            HStack {
                Text("先乘除后加减 · 保存时自动使用结果").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let result = AmountCalculation.evaluate(expression) {
                    Text("= \(result.formatted(.number.precision(.fractionLength(2))))").font(.callout.monospacedDigit())
                } else if !expression.isEmpty {
                    Text("请完善算式，除数不能为 0").font(.caption2).foregroundStyle(.red)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    Button { press(key) } label: {
                        Text(key).font(.title3.weight(.medium)).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered).tint(key == "=" ? .accentColor : .secondary)
                    .accessibilityLabel(key == "⌫" ? "删除末位" : key == "C" ? "清空金额" : key)
                }
            }
        }.padding(.vertical, 4)
    }

    private func press(_ key: String) {
        switch key {
        case "C": expression = ""; didEvaluate = false
        case "⌫": if !expression.isEmpty { expression.removeLast() }; didEvaluate = false
        case "=":
            if let result = AmountCalculation.evaluate(expression) { expression = String(result); didEvaluate = true }
        case "%":
            if let result = AmountCalculation.evaluate(expression + "÷100") { expression = String(result); didEvaluate = true }
        default:
            let isOperator = ["+", "−", "×", "÷"].contains(key)
            if didEvaluate && !isOperator { expression = "" }
            didEvaluate = false
            if isOperator, let last = expression.last, ["+", "−", "×", "÷"].contains(String(last)) { expression.removeLast() }
            expression += key
        }
    }
}
