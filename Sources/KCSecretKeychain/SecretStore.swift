import Foundation
import LocalAuthentication
import Security

public struct KeychainError: Error, CustomStringConvertible {
    public let description: String

    init(_ message: String, status: OSStatus? = nil) {
        if let status {
            let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
            description = "\(message): \(detail)"
        } else {
            description = message
        }
    }
}

/// The keychain kcsecret keeps its secrets in: a file of its own, not "login".
///
/// Items are generic passwords (service = the secret's name, account = the login name) whose
/// access list trusts only the binary that stored them. Other programs, including
/// `security find-generic-password -w`, get the keychain's password dialog instead. Reading goes
/// through `Authentication.require` first, so every read also needs Touch ID or the Mac password.
public final class SecretStore {
    /// The keychain's path without the `-db` suffix macOS adds on disk.
    public let path: String
    private let keychain: SecKeychain

    private init(path: String, keychain: SecKeychain) {
        self.path = path
        self.keychain = keychain
    }

    /// The path as given, minus a trailing `-db`, with `~` expanded.
    public static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasSuffix("-db") ? String(expanded.dropLast(3)) : expanded
    }

    public static func exists(at path: String) -> Bool {
        let base = normalize(path)
        return FileManager.default.fileExists(atPath: base + "-db") || FileManager.default.fileExists(atPath: base)
    }

    /// Opens the keychain at `path`. Returns nil when it does not exist yet; see `create`.
    public static func open(at path: String) throws -> SecretStore? {
        let base = normalize(path)
        guard exists(at: base) else { return nil }
        var keychain: SecKeychain?
        let status = SecKeychainOpen(base, &keychain)
        guard status == errSecSuccess, let keychain else { throw KeychainError("cannot open \(base)", status: status) }
        return SecretStore(path: base, keychain: keychain)
    }

    /// Creates the keychain. macOS asks the user to choose its password. It never locks on sleep
    /// or idle, and is added to the user's keychain list so Keychain Access shows it; being listed
    /// gives other programs no access to the items.
    public static func create(at path: String) throws -> SecretStore {
        let base = normalize(path)
        try FileManager.default.createDirectory(
            atPath: (base as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var keychain: SecKeychain?
        let status = SecKeychainCreate(base, 0, nil, true, nil, &keychain)  // macOS asks for its password
        guard status == errSecSuccess, let keychain else { throw KeychainError("cannot create \(base)", status: status) }
        var settings = SecKeychainSettings(
            version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1), lockOnSleep: false, useLockInterval: false,
            lockInterval: UInt32(INT32_MAX))
        SecKeychainSetSettings(keychain, &settings)
        var list: CFArray?
        SecKeychainCopyDomainSearchList(.user, &list)
        SecKeychainSetDomainSearchList(.user, (((list as? [SecKeychain]) ?? []) + [keychain]) as CFArray)
        return SecretStore(path: base, keychain: keychain)
    }

    public var isLocked: Bool {
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return true }
        return status & UInt32(kSecUnlockStateStatus) == 0
    }

    // MARK: Trust

    public enum Trust: Equatable, Sendable {
        /// The item's access list names this build (by its code signature): Touch ID only.
        case thisBuild
        /// Only other builds: macOS asks for the keychain password before this one may read it.
        case otherBuild
        /// Any application may read it without asking (not set by kcsecret; edited by hand).
        case anyApplication
        case unknown
    }

    /// The running binary's path, symlinks resolved.
    public static var executablePath: String? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }

    /// This binary's designated requirement, e.g. `identifier kcsecret and anchor apple generic …`,
    /// or `cdhash H"…"` for an ad hoc signature.
    public static var currentRequirement: String? {
        guard let path = executablePath else { return nil }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess
        else { return nil }
        return text as String?
    }

    /// `SecTrustedApplicationCopyRequirement`: exported by Security.framework and used by Apple's
    /// `security dump-keychain -a`, but not in the public headers, so it is looked up at run time.
    /// Without it, `trust(of:)` answers `.unknown`.
    private typealias CopyRequirement = @convention(c) (
        SecTrustedApplication, UnsafeMutablePointer<SecRequirement?>
    ) -> OSStatus
    private static let copyRequirement: CopyRequirement? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTrustedApplicationCopyRequirement")
        else { return nil }
        return unsafeBitCast(symbol, to: CopyRequirement.self)
    }()

    /// Who may read the item without a password dialog. Reads only the access list, never the
    /// secret, so it needs neither Touch ID nor the keychain password.
    public func trust(of name: String) -> Trust {
        var q = query(name)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnRef as String] = true
        var ref: CFTypeRef?
        var access: SecAccess?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess, let ref,
              SecKeychainItemCopyAccess(ref as! SecKeychainItem, &access) == errSecSuccess, let access,
              let me = Self.currentRequirement
        else { return .unknown }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL] else { return .unknown }
        var sawDecrypt = false
        for acl in acls {
            let tags = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard tags.contains(kSecACLAuthorizationDecrypt as String) || tags.contains(kSecACLAuthorizationAny as String)
            else { continue }
            sawDecrypt = true
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess else { continue }
            guard let trusted = apps as? [SecTrustedApplication] else { return .anyApplication }
            guard let copyRequirement = Self.copyRequirement else { return .unknown }
            for app in trusted {
                var requirement: SecRequirement?
                var text: CFString?
                if copyRequirement(app, &requirement) == errSecSuccess, let requirement,
                   SecRequirementCopyString(requirement, [], &text) == errSecSuccess, text as String? == me {
                    return .thisBuild
                }
            }
        }
        return sawDecrypt ? .otherBuild : .unknown
    }

    // MARK: Items

    private func query(_ name: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: NSUserName(),
            kSecMatchSearchList as String: [keychain],
        ]
        if let name { q[kSecAttrService as String] = name }
        return q
    }

    public func contains(_ name: String) -> Bool {
        var q = query(name)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Stores `secret` as `name`, replacing an existing item. Returns whether one was replaced.
    @discardableResult
    public func store(_ secret: String, as name: String) throws -> Bool {
        var me: SecTrustedApplication?
        var access: SecAccess?
        guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me,
              SecAccessCreate(name as CFString, [me] as CFArray, &access) == errSecSuccess, let access
        else { throw KeychainError("cannot create the access list for \(name)") }
        let removed = SecItemDelete(query(name) as CFDictionary)
        if removed == errSecInvalidOwnerEdit {
            throw KeychainError(
                "\(name) was stored by another kcsecret build, which alone may replace it: read it once and "
                    + "choose Always Allow, or delete it in Keychain Access (kcsecret keychain), then store it again")
        }
        guard removed == errSecSuccess || removed == errSecItemNotFound else {
            throw KeychainError("cannot replace the existing \(name)", status: removed)
        }
        var add = query(name)
        add.removeValue(forKey: kSecMatchSearchList as String)
        add[kSecUseKeychain as String] = keychain
        add[kSecAttrLabel as String] = name
        add[kSecAttrDescription as String] = "kcsecret"
        add[kSecAttrAccess as String] = access
        add[kSecValueData as String] = Data(secret.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError("cannot store \(name)", status: status) }
        return removed == errSecSuccess
    }

    /// The secret, or nil if there is no item by that name. Call `Authentication.require` first.
    public func read(_ name: String) throws -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8)
        else { throw KeychainError("cannot read \(name)", status: status) }
        return secret
    }

    /// Returns false if there was no item by that name.
    @discardableResult
    public func delete(_ name: String) throws -> Bool {
        let status = SecItemDelete(query(name) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError("cannot delete \(name)", status: status) }
        return true
    }

    public struct Item: Sendable {
        public let name: String
        public let modified: Date?
    }

    /// Every item's name and date, without reading any secret (so without Touch ID).
    public func items() throws -> [Item] {
        var q = query()
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
            throw KeychainError("cannot list \(path)", status: status)
        }
        return rows.compactMap { row in
            (row[kSecAttrService as String] as? String).map {
                Item(name: $0, modified: row[kSecAttrModificationDate as String] as? Date)
            }
        }.sorted { $0.name < $1.name }
    }
}

public enum Authentication {
    /// Asks for Touch ID, or the Mac password when no fingerprint is available.
    /// `reason` completes the sentence "kcsecret is trying to …".
    public static func require(reason: String) throws {
        let context = LAContext()
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            if !ok { failure = error ?? KeychainError("not authenticated") }
            done.signal()
        }
        done.wait()
        if let failure {
            if let la = failure as? LAError, la.code == .userCancel || la.code == .systemCancel || la.code == .appCancel {
                throw KeychainError("not authenticated: cancelled")
            }
            throw KeychainError("not authenticated: \(failure.localizedDescription)")
        }
    }
}
