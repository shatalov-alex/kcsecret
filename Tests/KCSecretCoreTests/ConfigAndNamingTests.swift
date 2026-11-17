import Testing
@testable import KCSecretCore

@Suite("NameTemplate")
struct NameTemplateTests {
    let context = NameTemplate.Context(project: "My Shop", path: "work/acme/My Shop", folder: "api", user: "alex")

    @Test func defaultTemplate() throws {
        let t = try NameTemplate(NameTemplate.defaultTemplate)
        #expect(t.render(variable: "OPENAI_API_KEY", context: context) == "My-Shop-openai-api-key")
    }

    @Test(arguments: [
        ("{var}", "OPENAI_API_KEY"),
        ("{var_lower}", "openai_api_key"),
        ("{user}.{project}.{folder}.{var_kebab}", "alex.My-Shop.api.openai-api-key"),
        ("prefix/{var}", "prefix-OPENAI_API_KEY"),
        ("{path}-{var_lower}", "work-acme-My-Shop-openai_api_key"),
        ("{path}-{env}-{var_lower}", "work-acme-My-Shop-openai_api_key"),
        ("{env}.{var}", "OPENAI_API_KEY"),
        ("{var}.{env}", "OPENAI_API_KEY"),
    ])
    func placeholders(template: String, expected: String) throws {
        #expect(try NameTemplate(template).render(variable: "OPENAI_API_KEY", context: context) == expected)
    }

    @Test func envFillsInWhenSet() throws {
        var prod = context
        prod.env = "prod"
        #expect(try NameTemplate("{path}-{env}-{var_lower}").render(variable: "DB_URL", context: prod)
            == "work-acme-My-Shop-prod-db_url")
    }

    @Test(arguments: [
        (".env", ""), (".env.prod", "prod"), (".env.prod.local", "prod.local"), (".env.local", ""),
        ("staging.env", "staging"), ("secrets", "secrets"),
    ])
    func environmentNames(file: String, env: String) {
        #expect(DotEnv.environmentName(fileName: file) == env)
    }

    @Test func valuesAreNotReinterpretedAsPlaceholders() throws {
        let tricky = NameTemplate.Context(project: "{var}", folder: "f", user: "u")
        #expect(try NameTemplate("{project}-{var}").render(variable: "X", context: tricky) == "var-X")
    }

    @Test(arguments: ["{project}", "{nope}-{var}", "{var", "plain"])
    func invalidTemplates(_ template: String) {
        #expect(throws: NameTemplate.InvalidTemplate.self) { try NameTemplate(template) }
    }

    @Test func sanitize() {
        #expect(SecretName.sanitize("  a b//c--") == "a-b-c")
        #expect(SecretName.isValid("a.b_c-1"))
        #expect(!SecretName.isValid("a b"))
        #expect(!SecretName.isValid(""))
    }
}

@Suite("Config")
struct ConfigTests {
    @Test func defaultsWhenEmpty() throws {
        #expect(try Config.parse("").config == Config())
    }

    @Test func parsesEverySetting() throws {
        let (config, warnings) = try Config.parse("""
            # comment
            keychain = "~/k.keychain"   # trailing comment
            name_template = '{var}'
            projects_root = "~/Developer"
            envrc_command = "kcsecret"
            clear_clipboard = false
            direnv_allow = false
            git_exclude = false
            import_selection = "all"
            import_strip = true
            future_setting = 1
            """)
        #expect(config.keychain == "~/k.keychain")
        #expect(config.nameTemplate == "{var}")
        #expect(config.projectsRoot == "~/Developer")
        #expect(config.envrcCommand == "kcsecret")
        #expect(!config.clearClipboard && !config.direnvAllow && !config.gitExclude)
        #expect(config.importSelection == .all)
        #expect(config.importStrip)
        #expect(warnings.count == 1)
    }

    @Test(arguments: [
        "keychain = unquoted", "clear_clipboard = yes", "import_selection = \"some\"",
        "name_template = \"{project}\"", "no equals sign",
    ])
    func rejectsBadValues(_ line: String) {
        #expect(throws: Config.ParseError.self) { try Config.parse(line) }
    }

    @Test func theTemplateFileParsesToTheDefaults() throws {
        let (config, warnings) = try Config.parse(Config.template)
        #expect(config == Config())
        #expect(warnings.isEmpty)
    }
}

@Suite("SecretHeuristics")
struct SecretHeuristicsTests {
    @Test(arguments: [
        "OPENAI_API_KEY", "GITHUB_TOKEN", "DB_PASSWORD", "JWT_SECRET", "STRIPE_SECRET_KEY", "DATABASE_URL",
        "SENTRY_DSN", "APIKEY", "AWS_SECRET_ACCESS_KEY", "SMTP_PASS", "SECRETS",
    ])
    func secrets(_ name: String) { #expect(SecretHeuristics.looksSecret(name)) }

    @Test(arguments: ["PORT", "DEBUG", "NODE_ENV", "AUTHOR", "KEYBOARD_LAYOUT", "LOG_LEVEL", "API_URL"])
    func notSecrets(_ name: String) { #expect(!SecretHeuristics.looksSecret(name)) }
}

@Suite("Shell")
struct ShellTests {
    @Test func quote() {
        #expect(Shell.quote("abc-1.2_x/y") == "abc-1.2_x/y")
        #expect(Shell.quote("") == "''")
        #expect(Shell.quote("a b") == "'a b'")
        #expect(Shell.quote("it's $x") == #"'it'\''s $x'"#)
        #expect(Shell.quote("line\nbreak") == "'line\nbreak'")
    }
}
