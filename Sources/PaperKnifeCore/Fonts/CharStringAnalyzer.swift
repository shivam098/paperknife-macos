/// Follows a Type 1 glyph program (Adobe Type 1 Font Format, chapter 6) far enough to tell what it
/// depends on: the subroutines it calls, directly or through other subroutines, and the glyphs an
/// accented glyph is built from (seac). Type 1 programs have no branches, so running them with the
/// operand values tracked finds exactly the subroutines a renderer runs. Hint replacement
/// ("subr# 1 3 callothersubr pop callsubr") is followed; a subroutine number that can't be known
/// fails the analysis.
enum CharStringAnalyzer {
    private static let maxDepth = 16
    private static let maxStack = 24

    /// A limit on the instructions run, shared by the analyses of one font, so a crafted font can't take long.
    final class Budget {
        var steps: Int

        init(_ steps: Int) {
            self.steps = steps
        }
    }

    /// The subroutines `program` calls, in the order it first calls them, and the StandardEncoding
    /// codes of the glyphs it is built from, or nil when the program can't be followed with certainty.
    static func analyze(_ program: [UInt8], _ subrs: [Int: [UInt8]], _ budget: Budget) -> (subrs: OrderedSet<Int>, components: [Int])? {
        let run = Run(subrs, budget)
        return run.execute(program, 0) == .failed ? nil : (run.called, run.components)
    }

    private enum Outcome {
        case `return`
        case end
        case failed
    }

    private final class Run {
        private let subrs: [Int: [UInt8]]
        private let budget: Budget

        // Unknown values are nil.
        private var stack: [Double?] = []
        private var knownResults = 0
        private var unknownResults: [Double?]?
        private var nextUnknown = 0

        private(set) var called = OrderedSet<Int>()

        private(set) var components: [Int] = []

        init(_ subrs: [Int: [UInt8]], _ budget: Budget) {
            self.subrs = subrs
            self.budget = budget
        }

        func execute(_ program: [UInt8], _ depth: Int) -> Outcome {
            if depth > maxDepth {
                return .failed
            }

            var i = 0
            while i < program.count {
                budget.steps -= 1
                if budget.steps < 0 {
                    return .failed
                }

                let v = Int(program[i])
                i += 1
                if v >= 32 {
                    guard let number = readNumber(program, v, &i), stack.count < maxStack else {
                        return .failed
                    }

                    stack.append(number)
                    continue
                }

                switch v {
                case 10: // callsubr
                    guard let index = tryPop(), let n = index, Self.isIndex(n), let subr = subrs[Int(n)] else {
                        return .failed
                    }

                    called.insert(Int(n))
                    let outcome = execute(subr, depth + 1)
                    if outcome != .return {
                        return outcome
                    }
                case 11: // return
                    return .return
                case 14: // endchar
                    return .end
                case 12:
                    if i >= program.count {
                        return .failed
                    }

                    let escaped = program[i]
                    i += 1
                    switch escaped {
                    case 6: // seac: asb adx ady bchar achar
                        guard stack.count >= 5, let baseCode = stack[stack.count - 2], let accentCode = stack[stack.count - 1],
                            Self.isCode(baseCode), Self.isCode(accentCode) else {
                            return .failed
                        }

                        components.append(Int(baseCode))
                        components.append(Int(accentCode))
                        return .end
                    case 12: // div
                        guard let divisor = tryPop(), let dividend = tryPop() else {
                            return .failed
                        }

                        if let d = divisor, let x = dividend, d != 0 {
                            stack.append(x / d)
                        } else {
                            stack.append(nil)
                        }
                    case 16: // callothersubr: arg1 ... argn n othersubr#
                        guard let other = tryPop(), let count = tryPop(), let o = other, let c = count, Self.isIndex(c),
                            c <= Double(stack.count), callOtherSubr(o, Int(c)) else {
                            return .failed
                        }
                    case 17: // pop: takes a result of the last callothersubr
                        if knownResults > 0 {
                            // Already on the stack, as FreeType puts it there.
                            knownResults -= 1
                        } else if let results = unknownResults, nextUnknown < results.count, stack.count < maxStack {
                            stack.append(results[nextUnknown])
                            nextUnknown += 1
                        } else {
                            return .failed
                        }
                    case 0, 1, 2, 7, 33: // dotsection, vstem3, hstem3, sbw, setcurrentpoint
                        stack.removeAll()
                    default:
                        return .failed
                    }
                case 1, 3, 4, 5, 6, 7, 8, 9, 13, 21, 22, 30, 31:
                    // hstem, vstem, vmoveto, rlineto, hlineto, vlineto, rrcurveto, closepath, hsbw,
                    // rmoveto, hmoveto, vhcurveto, hvcurveto: they use the operands and clear the stack.
                    stack.removeAll()
                default:
                    return .failed
                }
            }

            return .return
        }

        // As FreeType's t1decode.c: the results of the othersubrs it knows are put back on the
        // operand stack at once (the end point of a flex, the subroutine number for hint
        // replacement), and "pop" only consumes them; the arguments of others come back one per "pop".
        private func callOtherSubr(_ number: Double, _ count: Int) -> Bool {
            let arguments = Array(stack[(stack.count - count)...])
            stack.removeLast(count)
            knownResults = 0
            unknownResults = nil
            nextUnknown = 0
            switch number {
            case 0: // end of flex
                if count != 3 {
                    return false
                }

                stack.append(nil)
                stack.append(nil)
                knownResults = 2
                return true
            case 1, 2: // start of flex, a flex point
                return count == 0
            case 3: // hint replacement
                if count != 1 {
                    return false
                }

                stack.append(arguments[0])
                knownResults = 1
                return true
            default:
                unknownResults = arguments
                return true
            }
        }

        /// The top of the stack (nil inside when the value is unknown), or nil when the stack is empty.
        private func tryPop() -> Double?? {
            stack.isEmpty ? nil : .some(stack.removeLast())
        }

        private static func isIndex(_ value: Double) -> Bool { value >= 0 && value <= 65535 && value == value.rounded(.down) }

        private static func isCode(_ value: Double) -> Bool { value >= 0 && value <= 255 && value == value.rounded(.down) }
    }

    /// A number in a Type 1 glyph program (section 6.2), or nil when the program ends inside it.
    static func readNumber(_ program: [UInt8], _ v: Int, _ i: inout Int) -> Double? {
        if v <= 246 {
            return Double(v - 139)
        }

        if v <= 250 && i < program.count {
            let value = (v - 247) * 256 + Int(program[i]) + 108
            i += 1
            return Double(value)
        }

        if v <= 254 && i < program.count {
            let value = -((v - 251) * 256) - Int(program[i]) - 108
            i += 1
            return Double(value)
        }

        if v == 255 && i + 4 <= program.count {
            let bits = UInt32(program[i]) << 24 | UInt32(program[i + 1]) << 16 | UInt32(program[i + 2]) << 8 | UInt32(program[i + 3])
            i += 4
            return Double(Int32(bitPattern: bits))
        }

        return nil
    }
}
