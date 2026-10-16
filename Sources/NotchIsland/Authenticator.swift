import AppKit
import CoreImage
import CryptoKit
import LocalAuthentication
import Security
import SwiftUI

// MARK: - TOTP (RFC 6238), the codes Google Authenticator & co. show

enum OTPAlgorithm: String, Codable, CaseIterable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

/// One account. The setup key itself is not here: it lives encrypted in OTPVault.
struct OTPAccount: Codable, Identifiable, Equatable {
    var id = UUID()
    var issuer: String
    var account: String
    var digits = 6
    var period = 30
    var algorithm: OTPAlgorithm = .sha1
}

/// RFC 4648 Base32 (setup keys), ignoring spaces, dashes, padding and case.
func base32Decode(_ s: String) -> Data? {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var bits = 0, value = 0
    var out = Data()
    for ch in s.uppercased() where !" -=".contains(ch) {
        guard let i = alphabet.firstIndex(of: ch) else { return nil }
        value = (value << 5) | i
        bits += 5
        if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xFF)); bits -= 8 }
    }
    return out.isEmpty ? nil : out
}

func totp(secret: Data, at time: Date, digits: Int = 6, period: Int = 30, algorithm: OTPAlgorithm = .sha1) -> String {
    var counter = UInt64(time.timeIntervalSince1970 / Double(period)).bigEndian
    let message = Data(bytes: &counter, count: 8)
    let key = SymmetricKey(data: secret)
    let mac: [UInt8] = switch algorithm {
    case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
    case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
    case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
    }
    let offset = Int(mac[mac.count - 1] & 0x0F)
    let code = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
        | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
    var mod: UInt32 = 1
    for _ in 0..<digits { mod *= 10 }
    return String(format: "%0\(digits)u", code % mod)
}

/// `otpauth://totp/Issuer:account?secret=…&issuer=…&digits=6&period=30&algorithm=SHA1`
func parseOTPAuth(_ text: String) -> (OTPAccount, Data)? {
    guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          url.scheme == "otpauth", url.host == "totp" else { return nil }
    func q(_ name: String) -> String? { url.queryItems?.first { $0.name.lowercased() == name }?.value }
    guard let secret = q("secret").flatMap(base32Decode) else { return nil }
    let label = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
    let parts = label.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
    let issuer = q("issuer") ?? (parts.count == 2 ? parts[0] : "")
    let account = parts.count == 2 ? parts[1] : parts.first ?? ""
    var a = OTPAccount(issuer: issuer, account: account)
    if let d = q("digits").flatMap(Int.init), [6, 7, 8].contains(d) { a.digits = d }
    if let p = q("period").flatMap(Int.init), p > 0 { a.period = p }
    if let alg = q("algorithm").flatMap({ OTPAlgorithm(rawValue: $0.uppercased()) }) { a.algorithm = alg }
    return (a, secret)
}

/// Every otpauth:// link in pasted text: one per line, or separated by spaces or commas (bulk import).
func otpLinks(in text: String) -> [String] {
    text.split { $0.isWhitespace || $0 == "," }.map(String.init).filter { $0.lowercased().hasPrefix("otpauth://") }
}

/// Text of the first QR code in an image (no screen recording needed: it reads a picture you give it).
func qrText(in image: NSImage) -> String? {
    guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff),
          let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    else { return nil }
    return detector.features(in: ci).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
}

// MARK: - Storage for setup keys

/// Setup keys in a file, encrypted to a key held by this Mac's Secure Enclave, which uses it only after
/// Touch ID or your Mac password: other apps, other users and other Macs can't read them. (Not the
/// Keychain: it asks for the login-keychain password, which can differ from the Mac password, and asks
/// again after every update of a self-signed app.)
enum OTPVault {
    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchIsland/authenticator.vault")

    private struct Stored: Codable {
        var enclaveKey: Data  // the enclave's wrapped private key: useless off this Mac
        var publicKey: Data
        var ephemeral: Data   // a fresh key per save, so each save has its own secret
        var box: Data         // AES-GCM sealed JSON of [UUID: Data]
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Encrypting needs only the public key, so saving never asks for Touch ID.
    static func save(_ secrets: [UUID: Data]) throws {
        var stored: Stored
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = s
        } else {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                               [.privateKeyUsage, .userPresence], &error)
            else { throw error!.takeRetainedValue() as Error }
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            stored = Stored(enclaveKey: key.dataRepresentation, publicKey: key.publicKey.rawRepresentation, ephemeral: Data(), box: Data())
        }
        (stored.ephemeral, stored.box) = try seal(JSONEncoder().encode(secrets),
                                                  to: P256.KeyAgreement.PublicKey(rawRepresentation: stored.publicKey))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Shows the system Touch ID / Mac password sheet, then decrypts.
    static func load(reason: String) throws -> [UUID: Data] {
        let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
        let context = LAContext()
        context.localizedReason = reason
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: stored.enclaveKey, authenticationContext: context)
        let data = try open(stored.box, ephemeral: stored.ephemeral) { try key.sharedSecretFromKeyAgreement(with: $0) }
        return try JSONDecoder().decode([UUID: Data].self, from: data)
    }

    static func seal(_ data: Data, to recipient: P256.KeyAgreement.PublicKey) throws -> (ephemeral: Data, box: Data) {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let key = symmetricKey(try ephemeral.sharedSecretFromKeyAgreement(with: recipient), ephemeral.publicKey.rawRepresentation)
        return (ephemeral.publicKey.rawRepresentation, try AES.GCM.seal(data, using: key).combined!)
    }

    static func open(_ box: Data, ephemeral: Data, agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> Data {
        let secret = try agree(P256.KeyAgreement.PublicKey(rawRepresentation: ephemeral))
        return try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: symmetricKey(secret, ephemeral))
    }

    private static func symmetricKey(_ secret: SharedSecret, _ info: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("NotchIsland authenticator".utf8), sharedInfo: info, outputByteCount: 32)
    }

    static func delete() { try? FileManager.default.removeItem(at: file) }
}

/// Where earlier versions kept the keys: the login Keychain. Read once, then moved into OTPVault.
enum KeychainVault {
    private static let service = "dev.local.NotchIsland.authenticator"

    enum Read { case open([UUID: Data]), locked, failed(OSStatus) }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// `prompt: false` never shows the Keychain dialog: it answers `.locked` where macOS would ask.
    static func load(prompt: Bool, ids: [UUID]) -> Read {
        SecKeychainSetUserInteractionAllowed(prompt) // shortcut: deprecated API, but the only switch for this keychain's prompts
        defer { SecKeychainSetUserInteractionAllowed(true) }
        let (status, data) = read("vault")
        if status == errSecSuccess { return .open((try? JSONDecoder().decode([UUID: Data].self, from: data ?? Data())) ?? [:]) }
        guard status == errSecItemNotFound else { return locked(status) ? .locked : .failed(status) }
        // The oldest versions kept one item per account.
        var dict: [UUID: Data] = [:]
        for id in ids {
            let (s, key) = read(id.uuidString)
            if s == errSecItemNotFound { continue }
            guard s == errSecSuccess, let key else { return locked(s) ? .locked : .failed(s) }
            dict[id] = key
        }
        return .open(dict)
    }

    private static func locked(_ s: OSStatus) -> Bool {
        [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(s)
    }

    private static func read(_ account: String) -> (OSStatus, Data?) {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        return (s, out as? Data)
    }

    /// Deleting doesn't need the keys, so it never asks.
    static func deleteAll() {
        let q = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary
        while SecItemDelete(q) == errSecSuccess {}
    }
}

// MARK: - Accounts

@MainActor
final class Authenticator: ObservableObject {
    static let shared = Authenticator()

    /// Names, digits, period: no keys (those are in OTPVault).
    @Published private(set) var accounts: [OTPAccount] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: "otpAccounts") }
    }
    @Published var editing = false
    /// open: codes showing. locked: Touch ID / Mac password needed. keychain: keys still in the old Keychain item.
    enum VaultState { case open, locked, keychain }
    @Published private(set) var state = VaultState.open
    @Published private(set) var unlocking = false
    @Published private(set) var problem: String?
    private var secrets: [UUID: Data] = [:]   // decrypted once per launch

    private init() {
        accounts = UserDefaults.standard.data(forKey: "otpAccounts").flatMap { try? JSONDecoder().decode([OTPAccount].self, from: $0) } ?? []
        guard !accounts.isEmpty else { return }
        if OTPVault.exists { state = .locked } else { state = .keychain; unlock(prompt: false) } // moves old keys quietly if it can
    }

    var isOpen: Bool { state == .open }

    /// Runs off the main thread, so the island doesn't freeze while the system sheet is up.
    func unlock(prompt: Bool = true) {
        guard !unlocking, !isOpen, prompt || state == .keychain else { return }
        unlocking = true
        problem = nil
        let fromKeychain = state == .keychain, ids = accounts.map(\.id)
        Task.detached {
            let result: Result<[UUID: Data], Error>
            if fromKeychain {
                switch KeychainVault.load(prompt: prompt, ids: ids) {
                case .open(let keys):
                    result = Result { try OTPVault.save(keys); KeychainVault.deleteAll(); return keys }
                case .locked: result = .failure(CancellationError())
                case .failed(let s): result = .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(s)))
                }
            } else {
                result = Result { try OTPVault.load(reason: "show your two-step codes") }
            }
            await MainActor.run {
                self.unlocking = false
                switch result {
                case .success(let keys):
                    self.secrets = keys
                    self.state = .open
                case .failure(let e):
                    let cancelled = e is CancellationError || [.userCancel, .appCancel, .systemCancel].contains((e as? LAError)?.code)
                    if !cancelled { self.problem = e.localizedDescription }
                }
            }
        }
    }

    /// Escape hatch when the keys can't be unlocked: forget every account and key, start empty.
    func removeAll() {
        OTPVault.delete()
        KeychainVault.deleteAll()
        secrets = [:]
        accounts = []
        state = .open
        problem = nil
        editing = false
    }

    func code(_ a: OTPAccount, at date: Date) -> String? {
        guard let s = secrets[a.id] else { return nil }
        return totp(secret: s, at: date, digits: a.digits, period: a.period, algorithm: a.algorithm)
    }

    /// Adds every otpauth:// link in `text`, each named from its link, or one bare setup key named by
    /// `issuer` / `account` (which also override the names of a single link). Accounts already here are skipped.
    /// nil when everything was added; otherwise what went wrong (the readable links are still added).
    func add(text: String, issuer: String, account: String) -> String? {
        // The vault holds every key: it must be open, or saving would drop the others.
        guard isOpen else { return "Unlock the Authenticator widget first (click Unlock on it)." }
        let links = otpLinks(in: text)
        var found: [(OTPAccount, Data)] = []
        var unreadable = 0
        if links.isEmpty {
            guard let key = base32Decode(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return "That isn't an otpauth:// link or a valid setup key."
            }
            found = [(OTPAccount(issuer: issuer, account: account), key)]
        } else {
            for link in links { if let p = parseOTPAuth(link) { found.append(p) } else { unreadable += 1 } }
            if links.count == 1, var only = found.first?.0 {
                if !issuer.isEmpty { only.issuer = issuer }
                if !account.isEmpty { only.account = account }
                found[0].0 = only
            }
        }
        var all = secrets, added: [OTPAccount] = []
        for (var a, key) in found {
            if a.issuer.isEmpty && a.account.isEmpty { a.issuer = "Account" }
            let known = (accounts + added).contains { $0.issuer == a.issuer && $0.account == a.account && all[$0.id] == key }
            if known { continue }
            all[a.id] = key
            added.append(a)
        }
        if !added.isEmpty {
            do { try OTPVault.save(all) } catch { return "Couldn't save the keys: \(error.localizedDescription)" }
            secrets = all
            accounts += added
        }
        if unreadable > 0 { return "Added \(added.count); \(unreadable) link\(unreadable == 1 ? "" : "s") couldn't be read (no valid secret, or not TOTP)." }
        if added.isEmpty { return "Already added." }
        return nil
    }

    func remove(_ a: OTPAccount) {
        guard isOpen else { return }
        var all = secrets
        all[a.id] = nil
        guard (try? OTPVault.save(all)) != nil else { return }
        secrets = all
        accounts.removeAll { $0.id == a.id }
    }

    func move(_ a: OTPAccount, by d: Int) {
        guard let i = accounts.firstIndex(of: a), accounts.indices.contains(i + d) else { return }
        accounts.swapAt(i, i + d)
    }

    /// Marked concealed + transient, so clipboard managers (ours too) don't keep it.
    /// The account whose row says "Copied" for a moment (shown right on the row you clicked).
    @Published private(set) var copiedID: UUID?
    private var copiedClear: DispatchWorkItem?

    func copy(_ code: String, from a: OTPAccount) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")], owner: nil)
        pb.setString(code, forType: .string)
        pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        pb.setString("", forType: .init("org.nspasteboard.TransientType"))
        withAnimation(.easeOut(duration: 0.15)) { copiedID = a.id }
        copiedClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.2)) { self?.copiedID = nil } }
        copiedClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: clear)
    }
}

// MARK: - Tile

struct AuthenticatorTile: View {
    @ObservedObject var auth = Authenticator.shared
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TileHeader(symbol: "key.fill", title: "AUTHENTICATOR")
                Spacer()
                Button { OTPAddWindow.shared.show() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add account…")
                if !auth.accounts.isEmpty {
                    Button { auth.editing.toggle() } label: { Image(systemName: auth.editing ? "checkmark" : "pencil") }
                        .buttonStyle(.plain).help(auth.editing ? "Done" : "Edit accounts")
                }
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary)
            if auth.accounts.isEmpty {
                Spacer(minLength: 0)
                Hint("Press + to add an account (QR code, otpauth link or setup key).", always: true)
                Spacer(minLength: 0)
            } else if !auth.isOpen {
                Spacer(minLength: 0)
                locked
                Spacer(minLength: 0)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(auth.accounts) { a in row(a, at: ctx.date) }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func row(_ a: OTPAccount, at date: Date) -> some View {
        let code = auth.code(a, at: date)
        let left = a.period - Int(date.timeIntervalSince1970) % a.period
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(a.issuer.isEmpty ? a.account : a.issuer).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondary).lineLimit(1)
                Text(auth.copiedID == a.id ? "Copied ✓" : code.map(spaced) ?? "Key missing").font(.system(size: size.width < 160 ? 14 : 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(left <= 5 ? Color.orange : theme.text).lineLimit(1).minimumScaleFactor(0.7)
                if size.width >= 220, !a.issuer.isEmpty, !a.account.isEmpty {
                    Text(a.account).font(.system(size: 9)).foregroundStyle(theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if auth.editing {
                TileButton(symbol: "chevron.up", size: 10) { auth.move(a, by: -1) }
                TileButton(symbol: "trash", size: 10) { auth.remove(a) }
            } else {
                // Seconds left until the next code.
                ZStack {
                    Circle().stroke(theme.secondary.opacity(0.25), lineWidth: 2.5)
                    Circle().trim(from: 0, to: CGFloat(left) / CGFloat(a.period))
                        .stroke(left <= 5 ? Color.orange : theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(left)").font(.system(size: 8, weight: .semibold).monospacedDigit()).foregroundStyle(theme.secondary)
                }
                .frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(theme.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { if !auth.editing, let code { auth.copy(code, from: a) } }
        .help(auth.editing ? "" : "Click to copy")
    }

    /// Keys are encrypted until Touch ID or your Mac password: one click per launch.
    @ViewBuilder private var locked: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(auth.state == .keychain
                 ? "Your keys are still in the old Keychain storage. Unlock once with the login keychain password to move them to Touch ID / Mac password."
                 : "Locked. Unlock with Touch ID or your Mac password.")
                .font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(3)
            if let p = auth.problem { Text(p).font(.system(size: 10)).foregroundStyle(Color.orange).lineLimit(2) }
            Button { auth.unlock() } label: {
                Label(auth.unlocking ? "Waiting…" : "Unlock", systemImage: auth.state == .keychain ? "lock.open" : "touchid")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent).disabled(auth.unlocking)
            Button("Can't unlock? Remove all accounts…") { confirmRemoveAll() }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(theme.secondary)
        }
    }

    private func confirmRemoveAll() {
        let alert = NSAlert()
        alert.messageText = "Remove all authenticator accounts?"
        alert.informativeText = "Their setup keys are deleted from this Mac. To get codes again, add each account from its website's 2-step settings."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { auth.removeAll() }
    }

    private func spaced(_ code: String) -> String {
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[..<mid] + " " + code[mid...]
    }
}

// MARK: - Add account window (typing needs keyboard focus, which the island never takes)

@MainActor
final class OTPDraft: ObservableObject {
    static let shared = OTPDraft()
    @Published var text = ""
    @Published var issuer = ""
    @Published var account = ""
    @Published var error: String?
}

struct OTPAddView: View {
    @ObservedObject var d = OTPDraft.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan the QR code a site shows when you turn on two-step sign-in, or paste its setup key.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { readQR(from: NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage) } label: {
                    Label("QR from Clipboard", systemImage: "doc.on.clipboard")
                }
                .help("Take a screenshot of the QR code to the clipboard (⌃⇧⌘4), then click")
                Button { chooseImage() } label: { Label("QR from Image…", systemImage: "photo") }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $d.text).font(.system(size: 12, design: .monospaced)).frame(height: 90)
                if d.text.isEmpty {
                    Text("otpauth://… links (one per line, for several at once) or a setup key")
                        .font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            let links = otpLinks(in: d.text)
            if links.count > 1 {
                // Bulk: each account is named from its own link.
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(links.count) accounts found").font(.caption.weight(.semibold))
                    ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                        if let (a, _) = parseOTPAuth(link) {
                            Label([a.issuer, a.account].filter { !$0.isEmpty }.joined(separator: " · "), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Can't read: \(link.prefix(48))…", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
                .font(.caption)
            } else {
                HStack {
                    TextField("Issuer (e.g. GitHub)", text: $d.issuer)
                    TextField("Account (e.g. you@example.com)", text: $d.account)
                }
            }
            if let e = d.error { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Keys are encrypted on this Mac; Touch ID or your Mac password unlocks them.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let e = Authenticator.shared.add(text: d.text, issuer: d.issuer, account: d.account) { d.error = e }
                    else { NSApp.keyWindow?.close() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(d.text.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onChange(of: d.text) { _, text in
            // One link: fill in its names (you can still change them).
            let links = otpLinks(in: text)
            if links.count == 1, let (a, _) = parseOTPAuth(links[0]) { d.issuer = a.issuer; d.account = a.account }
        }
    }

    private func readQR(from image: NSImage?) {
        guard let image else { d.error = "There's no picture on the clipboard."; return }
        guard let text = qrText(in: image) else { d.error = "No QR code found in that picture."; return }
        d.text = text
        d.error = parseOTPAuth(text) == nil ? "That QR code isn't an authenticator code." : nil
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { readQR(from: NSImage(contentsOf: url)) }
    }
}

@MainActor
final class OTPAddWindow {
    static let shared = OTPAddWindow()
    private var window: NSWindow?

    /// `text`: links to add, e.g. from an otpauth:// link clicked in a browser.
    func show(text: String = "") {
        let d = OTPDraft.shared
        d.text = ""; d.issuer = ""; d.account = ""; d.error = nil
        d.text = text
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OTPAddView()))
            w.title = "Add Authenticator Account"
            w.styleMask = [.titled, .closable]
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        IslandModel.shared.dismiss() // close the island you clicked + in, so it doesn't sit over the window
        NSApp.activate(ignoringOtherApps: true)
        window?.orderFrontRegardless()
        window?.makeKey()
    }
}
