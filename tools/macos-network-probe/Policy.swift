import Foundation
import Network
import Security
import NetworkExtension

struct ApplicationPolicy {
    let paths: [String]
    private let cache = NSCache<NSData, NSNumber>()

    init(configuration: [String: Any]?) throws {
        paths = configuration?["applicationPaths"] as? [String] ?? []
        cache.countLimit = 2048
        guard paths.allSatisfy({ $0.hasPrefix("/") && $0.hasSuffix(".app") && !$0.contains("/../") }) else {
            throw NSError(domain: "NetworkProbe", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "应用路径必须指向本机的 .app 文件夹"])
        }
    }

    func appRules() throws -> [NEAppRule] {
        try (paths + ["/Applications/CCSwitchEgressProbe.app"]).map { path in
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
                  let code else { throw URLError(.cannotOpenFile) }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let information = information as? [String: Any],
                  let identifier = information[kSecCodeInfoIdentifier as String] as? String else {
                throw URLError(.cannotParseResponse)
            }
            var requirement: SecRequirement?
            var requirementText: CFString?
            guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
                  let requirement,
                  SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess,
                  let requirementText else {
                throw URLError(.cannotParseResponse)
            }
            return NEAppRule(signingIdentifier: identifier, designatedRequirement: requirementText as String)
        }
    }

    func includes(token: Data?, signingIdentifier: String? = nil) -> Bool {
        if signingIdentifier == "com.ccswitch.egress-client-probe" { return true }
        guard let token else { return false }
        if let value = cache.object(forKey: token as NSData) { return value.boolValue }
        let result = includesUncached(token: token)
        cache.setObject(NSNumber(value: result), forKey: token as NSData)
        return result
    }

    private func includesUncached(token: Data) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary,
                                            [], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let information = information as? [String: Any] else { return false }
        if information[kSecCodeInfoIdentifier as String] as? String == "com.ccswitch.egress-client-probe" {
            return true
        }
        guard let executable = information[kSecCodeInfoMainExecutable as String] as? URL else { return false }
        let path = executable.standardizedFileURL.path
        return paths.contains { path.hasPrefix($0 + "/Contents/") }
    }
}
