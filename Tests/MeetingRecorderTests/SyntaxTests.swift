import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func spans(_ line: String, _ language: SyntaxLanguage = .python, state: SyntaxState = .code) -> [SyntaxSpan] {
    var state = state
    return SyntaxLogic.tokenize(line, language: language, state: &state)
}

private func kinds(_ line: String, _ language: SyntaxLanguage = .python) -> [String: SyntaxKind] {
    Dictionary(spans(line, language).compactMap { span in span.kind.map { (span.text, $0) } }, uniquingKeysWith: { first, _ in first })
}

let syntaxTests: [(name: String, run: () throws -> Void)] = [
    ("python keywords, builtins, numbers and def names are coloured, and the spans join back to the line", {
        let line = "    def order_to_pay(self, amount=1_000.5) -> None: return len(x) if not amount else 0x1F"
        check(spans(line).map(\.text).joined() == line, "joined")
        let found = kinds(line)
        check(found["def"] == .keyword && found["order_to_pay"] == .definition, "\(found)")
        check(found["self"] == .builtin && found["len"] == .builtin, "builtins")
        check(found["None"] == .keyword && found["return"] == .keyword && found["not"] == .keyword, "keywords")
        check(found["1_000.5"] == .number && found["0x1F"] == .number, "numbers")
        check(found["amount"] == nil && found["x"] == nil, "plain names")
        check(kinds("class Invoice(Base):")["Invoice"] == .definition, "class name")
        check(kinds("result.print(type)")["print"] == nil, "a member is not a builtin")
    }),

    ("python strings and comments, with escapes and a # inside a string", {
        check(spans(#"x = "a # \"b\"" # done"#) == [SyntaxSpan(text: "x = "), SyntaxSpan(text: #""a # \"b\"""#, kind: .string),
                                                    SyntaxSpan(text: " "), SyntaxSpan(text: "# done", kind: .comment)], "\(spans(#"x = "a # \"b\"" # done"#))")
        check(kinds("name = 'it' + rb'\\d'")["rb'\\d'"] == .string, "byte prefix")
        check(spans("s = 'open").last == SyntaxSpan(text: "'open", kind: .string), "an unclosed single quote ends with the line")
    }),

    ("f-strings are one string with their prefix", {
        let line = #"log(f"{user.name!r} paid {amount:.2f}", F'x')"#
        let found = kinds(line)
        check(found[#"f"{user.name!r} paid {amount:.2f}""#] == .string && found["F'x'"] == .string, "\(found)")
        check(found["f"] == nil, "the prefix is not a name")
    }),

    ("a triple-quoted string carries over lines, and a single quote does not", {
        let quotes = "\"\"\""
        var state = SyntaxState.code
        let first = SyntaxLogic.tokenize("    doc = \(quotes)Starts here", language: .python, state: &state)
        check(first.last == SyntaxSpan(text: "\(quotes)Starts here", kind: .string) && state == .string(close: quotes), "\(first) \(state)")
        let middle = SyntaxLogic.tokenize("    it's still # inside", language: .python, state: &state)
        check(middle == [SyntaxSpan(text: "    it's still # inside", kind: .string)], "\(middle)")
        let last = SyntaxLogic.tokenize("    ends\(quotes) + x  # tail", language: .python, state: &state)
        check(last.first == SyntaxSpan(text: "    ends\(quotes)", kind: .string) && last.last?.kind == .comment && state == .code, "\(last)")
        _ = SyntaxLogic.tokenize("x = 'a", language: .python, state: &state)
        check(state == .code, "single quote")
    }),

    ("decorators keep their dotted name, and @ between operands is not one", {
        check(spans("@app.route('/x')").first == SyntaxSpan(text: "@app.route", kind: .decorator), "\(spans("@app.route('/x')"))")
        check(kinds("    @staticmethod")["@staticmethod"] == .decorator, "indented")
        check(kinds("m = a @ b").values.allSatisfy { $0 != .decorator }, "matrix multiply")
    }),

    ("javascript keywords, template literals across lines, and block comments", {
        let line = "export const useAuth = defineStore('auth', { count: 0 }) // store"
        let found = kinds(line, .javaScript)
        check(found["export"] == .keyword && found["const"] == .keyword && found["'auth'"] == .string, "\(found)")
        check(found["0"] == .number && found["// store"] == .comment && found["useAuth"] == nil, "rest")
        check(kinds("async function load(id) {", .javaScript)["load"] == .definition, "function name")
        var state = SyntaxState.code
        _ = SyntaxLogic.tokenize("const t = `${a}", language: .javaScript, state: &state)
        check(state == .string(close: "`"), "template literal stays open")
        _ = SyntaxLogic.tokenize("done` /* note", language: .javaScript, state: &state)
        check(state == .comment(close: "*/"), "block comment opens \(state)")
        let closing = SyntaxLogic.tokenize("still */ return x", language: .javaScript, state: &state)
        check(closing.first == SyntaxSpan(text: "still */", kind: .comment) && state == .code, "\(closing)")
    }),

    ("swift attributes and declarations", {
        let found = kinds("@MainActor final class GitHubDiffModel: ObservableObject {", .swift)
        check(found["@MainActor"] == .decorator && found["class"] == .keyword && found["GitHubDiffModel"] == .definition, "\(found)")
    }),

    ("the language comes from the extension, and unknown files stay plain", {
        check(SyntaxLanguage.forPath("finq/jobs/sending.py")?.extensions == SyntaxLanguage.python.extensions, "python")
        check(SyntaxLanguage.forPath("src/App.TSX")?.extensions == SyntaxLanguage.javaScript.extensions, "tsx")
        check(SyntaxLanguage.forPath("lib/util.mjs") != nil && SyntaxLanguage.forPath("Package.swift") != nil, "mjs and swift")
        check(SyntaxLanguage.forPath("README.md") == nil && SyntaxLanguage.forPath("Makefile") == nil, "plain")
        check(GitHubDiffLogic.render("@@ -1 +1 @@\n-a\n+b", path: "notes.txt").spans == nil, "no spans for plain files")
    }),

    ("a diff keeps the old and new sides apart and resets at each hunk", {
        let patch = "@@ -1,3 +1,3 @@\n-x = \"\"\"old\n+x = 1\n y = 2\n@@ -9 +9 @@\n z = \"\"\"next"
        let render = GitHubDiffLogic.render(patch, path: "a.py")
        let spans = render.spans ?? []
        check(spans.count == render.rows.count, "one entry per row")
        check(spans[2].contains(SyntaxSpan(text: "1", kind: .number)), "added line is code \(spans[2])")
        check(spans[3].contains(SyntaxSpan(text: "2", kind: .number)), "context follows the new side \(spans[3])")
        check(spans[4].isEmpty && spans[5].last?.kind == .string, "hunk header")
    }),
]
