import Foundation

/// Turns an environment variable into a keychain item name, for example
/// `{project}-{env}-{var_kebab}` + `OPENAI_API_KEY` in `~/code/shop` → `shop-openai-api-key`, or
/// `shop-prod-openai-api-key` for the prod environment.
///
/// Placeholders:
///
/// | placeholder   | value for `OPENAI_API_KEY` in `~/code/My Shop/api` (git root `My Shop`) |
/// | ------------- | ----------------------------------------------------------------------- |
/// | `{var}`       | `OPENAI_API_KEY`                                                        |
/// | `{var_lower}` | `openai_api_key`                                                        |
/// | `{var_kebab}` | `openai-api-key`                                                        |
/// | `{project}`   | `My-Shop` (the git repository's folder, else the current folder)       |
/// | `{path}`      | the project folder's path under `projects_root`, `/` → `-`:             |
/// |               | `~/Developer/work/acme/My Shop` with root `~/Developer` → `work-acme-My-Shop` |
/// | `{env}`       | the .env file's environment: `prod` for `.env.prod`, empty for `.env`    |
/// | `{folder}`    | `api` (the folder holding `.envrc`)                                     |
/// | `{user}`      | the login name                                                          |
///
/// Characters a name may not contain (anything but letters, digits, `.`, `_` and `-`) become `-`.
public struct NameTemplate: Equatable, Sendable {
    public static let defaultTemplate = "{project}-{env}-{var_kebab}"
    public static let placeholders = ["var", "var_lower", "var_kebab", "project", "path", "env", "folder", "user"]

    public struct Context: Sendable {
        public var project: String
        /// The project folder relative to `projects_root`, e.g. `work/acme/shop`.
        public var path: String
        /// The environment a `.env` file is for (`prod` for `.env.prod`), or empty.
        public var env: String
        public var folder: String
        public var user: String

        public init(project: String, path: String? = nil, env: String = "", folder: String, user: String) {
            self.project = project
            self.path = path ?? project
            self.env = env
            self.folder = folder
            self.user = user
        }
    }

    public struct InvalidTemplate: Error, Equatable, CustomStringConvertible {
        public let template: String
        public let reason: String
        public var description: String { "invalid name template '\(template)': \(reason)" }
    }

    public let template: String

    public init(_ template: String) throws {
        self.template = template
        var rest = Substring(template)
        var sawVariable = false
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else {
                throw InvalidTemplate(template: template, reason: "a '{' is never closed")
            }
            let name = String(rest[rest.index(after: open)..<close])
            guard Self.placeholders.contains(name) else {
                throw InvalidTemplate(
                    template: template,
                    reason: "unknown placeholder {\(name)}; use one of "
                        + Self.placeholders.map { "{\($0)}" }.joined(separator: ", "))
            }
            if name.hasPrefix("var") { sawVariable = true }
            rest = rest[rest.index(after: close)...]
        }
        guard sawVariable else {
            throw InvalidTemplate(
                template: template, reason: "it needs {var}, {var_lower} or {var_kebab}, or every variable gets the same name")
        }
    }

    public func render(variable: String, context: Context) -> String {
        let values: [String: String] = [
            "var": variable,
            "var_lower": variable.lowercased(),
            "var_kebab": variable.lowercased().replacingOccurrences(of: "_", with: "-"),
            "project": context.project,
            "path": context.path.split(separator: "/").joined(separator: "-"),
            "env": context.env,
            "folder": context.folder,
            "user": context.user,
        ]
        let separators: Set<Character> = ["-", ".", "_"]
        var output = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            output += rest[..<open]
            let value = values[String(rest[rest.index(after: open)..<close])] ?? ""
            rest = rest[rest.index(after: close)...]
            if value.isEmpty {
                // An empty placeholder takes one separator with it: "{path}-{env}-{var}" with no env
                // gives "path-var", not "path--var".
                if let next = rest.first, separators.contains(next), output.last.map(separators.contains) ?? true {
                    rest = rest.dropFirst()
                } else if let last = output.last, separators.contains(last), rest.isEmpty || rest.first == "{" {
                    output.removeLast()
                }
            }
            output += value
        }
        output += rest
        return SecretName.sanitize(output)
    }
}

public enum SecretName {
    /// Letters, digits, `.`, `_` and `-`: safe as a keychain service name and in a shell word.
    public static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy(isAllowed)
    }

    /// Replaces disallowed characters with `-`, merges runs of `-` and trims `-` from the ends.
    public static func sanitize(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            let c: Unicode.Scalar = isAllowed(scalar) ? scalar : "-"
            if c == "-", out.unicodeScalars.last == "-" { continue }
            out.unicodeScalars.append(c)
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    private static func isAllowed(_ c: Unicode.Scalar) -> Bool {
        c.isASCIILetter || c.isASCIIDigit || c == "." || c == "_" || c == "-"
    }
}
