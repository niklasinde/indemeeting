import Foundation

enum SyntaxKind: Equatable { case keyword, builtin, string, number, comment, decorator, definition }

/// A piece of a line; the spans of a line always join back to the line itself.
struct SyntaxSpan: Equatable {
    let text: String
    var kind: SyntaxKind?
}

/// What an unfinished line leaves open for the next one.
enum SyntaxState: Equatable {
    case code
    case string(close: String)
    case comment(close: String)
}

/// The rules of one language: adding a language is adding one of these to `all`.
struct SyntaxLanguage {
    let extensions: Set<String>
    let keywords: Set<String>
    let builtins: Set<String>
    /// Keywords whose next word is the name being declared.
    let definers: Set<String>
    let lineComment: String
    var blockComment: (open: String, close: String)?
    /// Longest first, so `"""` wins over `"`.
    let quotes: [String]
    let multilineQuotes: Set<String>
    /// Letters that may stand before a quote, like Python's `f"…"` or `rb'…'`.
    var stringPrefixes: Set<Character> = []

    static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

    static let python = SyntaxLanguage(
        extensions: ["py", "pyi", "pyw"],
        keywords: words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield"),
        builtins: words("self cls print len range str int float bool bytes list dict set frozenset tuple object type super isinstance issubclass open enumerate zip map filter sorted reversed min max sum any all abs round getattr setattr hasattr delattr repr hash id iter next callable format vars dir property staticmethod classmethod Exception BaseException ValueError TypeError KeyError IndexError AttributeError RuntimeError NotImplementedError StopIteration"),
        definers: ["def", "class"],
        lineComment: "#",
        quotes: ["\"\"\"", "'''", "\"", "'"],
        multilineQuotes: ["\"\"\"", "'''"],
        stringPrefixes: ["r", "R", "b", "B", "f", "F", "u", "U"])

    static let javaScript = SyntaxLanguage(
        extensions: ["js", "jsx", "ts", "tsx", "mjs", "cjs"],
        keywords: words("abstract as async await break case catch class const continue debugger declare default delete do else enum export extends false finally for from function if implements import in instanceof interface keyof let namespace new null of private protected public readonly return static super switch this throw true try typeof undefined var void while with yield"),
        builtins: words("console window document globalThis Math JSON Object Array String Number Boolean Promise Map Set Date Error RegExp Symbol parseInt parseFloat require module exports process"),
        definers: ["function", "class", "interface", "enum"],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'", "`"],
        multilineQuotes: ["`"])

    static let swift = SyntaxLanguage(
        extensions: ["swift"],
        keywords: words("actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is let mutating nil nonisolated open operator override private protocol public repeat rethrows return some static struct subscript switch throw throws true try typealias var weak where while"),
        builtins: words("self Self super String Int Double Float Bool Character Array Dictionary Set Optional Result Error Data Date URL Task print"),
        definers: ["func", "class", "struct", "enum", "protocol", "actor", "extension", "typealias"],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        quotes: ["\"\"\"", "\""],
        multilineQuotes: ["\"\"\""])

    static let all = [python, javaScript, swift]

    static func forPath(_ path: String) -> SyntaxLanguage? {
        let ext = (path as NSString).pathExtension.lowercased()
        return all.first { $0.extensions.contains(ext) }
    }
}

enum SyntaxLogic {
    /// Splits a line into coloured spans, continuing from `state` and leaving it set for the next line.
    static func tokenize(_ line: String, language: SyntaxLanguage, state: inout SyntaxState) -> [SyntaxSpan] {
        let chars = Array(line)
        var spans: [SyntaxSpan] = []
        var plainStart = 0
        var index = 0
        var declaring = false

        func emit(_ end: Int, _ kind: SyntaxKind) {
            if plainStart < index { spans.append(SyntaxSpan(text: String(chars[plainStart..<index]))) }
            spans.append(SyntaxSpan(text: String(chars[index..<end]), kind: kind))
            index = end
            plainStart = end
        }

        func matches(_ token: String, at position: Int) -> Bool {
            let token = Array(token)
            return !token.isEmpty && position + token.count <= chars.count && Array(chars[position..<position + token.count]) == token
        }

        func end(of close: String, from start: Int, escapes: Bool) -> Int? {
            var position = start
            while position < chars.count {
                if escapes && chars[position] == "\\" { position += 2; continue }
                if matches(close, at: position) { return position + close.count }
                position += 1
            }
            return nil
        }

        func close(_ marker: String, kind: SyntaxKind, from start: Int, spansLines: Bool) {
            if let found = end(of: marker, from: start, escapes: kind == .string) {
                state = .code
                emit(found, kind)
            } else {
                state = !spansLines ? .code : kind == .string ? .string(close: marker) : .comment(close: marker)
                emit(chars.count, kind)
            }
        }

        switch state {
        case .code: break
        case .string(let quote): close(quote, kind: .string, from: 0, spansLines: true)
        case .comment(let marker): close(marker, kind: .comment, from: 0, spansLines: true)
        }

        while index < chars.count {
            let char = chars[index]
            if matches(language.lineComment, at: index) {
                emit(chars.count, .comment)
            } else if let block = language.blockComment, matches(block.open, at: index) {
                close(block.close, kind: .comment, from: index + block.open.count, spansLines: true)
            } else if let quote = language.quotes.first(where: { matches($0, at: index) }) {
                close(quote, kind: .string, from: index + quote.count, spansLines: language.multilineQuotes.contains(quote))
            } else if char == "@", index + 1 < chars.count, isWordStart(chars[index + 1]) {
                var stop = index + 1
                while stop < chars.count, isWordPart(chars[stop]) || chars[stop] == "." { stop += 1 }
                emit(stop, .decorator)
            } else if char.isNumber || (char == "." && index + 1 < chars.count && chars[index + 1].isNumber && !isWordPart(index > 0 ? chars[index - 1] : " ")) {
                var stop = index + 1
                while stop < chars.count, isWordPart(chars[stop]) || chars[stop] == "." { stop += 1 }
                emit(stop, .number)
            } else if isWordStart(char) {
                var stop = index + 1
                while stop < chars.count, isWordPart(chars[stop]) { stop += 1 }
                let word = String(chars[index..<stop])
                if stop - index <= 2, word.allSatisfy(language.stringPrefixes.contains),
                   let quote = language.quotes.first(where: { matches($0, at: stop) }) {
                    close(quote, kind: .string, from: stop + quote.count, spansLines: language.multilineQuotes.contains(quote))
                } else if index > 0 && chars[index - 1] == "." {
                    declaring = false
                    index = stop
                } else if declaring && !language.keywords.contains(word) {
                    declaring = false
                    emit(stop, .definition)
                } else if language.keywords.contains(word) {
                    declaring = language.definers.contains(word)
                    emit(stop, .keyword)
                } else if language.builtins.contains(word) {
                    emit(stop, .builtin)
                } else {
                    declaring = false
                    index = stop
                }
            } else {
                if !char.isWhitespace { declaring = false }
                index += 1
            }
        }
        if plainStart < chars.count { spans.append(SyntaxSpan(text: String(chars[plainStart...]))) }
        return spans
    }

    private static func isWordStart(_ char: Character) -> Bool { char.isLetter || char == "_" || char == "$" }
    private static func isWordPart(_ char: Character) -> Bool { isWordStart(char) || char.isNumber }
}
