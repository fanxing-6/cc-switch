import Foundation
import Security

struct TestProfile {
    private static func signature(_ path: String) throws -> (String, String) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { throw URLError(.cannotOpenFile) }
        var information: CFDictionary?
        var requirement: SecRequirement?
        var requirementText: CFString?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess,
              let requirementText else { throw URLError(.cannotParseResponse) }
        return (identifier, requirementText as String)
    }

    private static func payload(_ type: String, _ suffix: String, _ name: String) -> [String: Any] {
        ["PayloadType": type, "PayloadVersion": 1, "PayloadUUID": UUID().uuidString,
         "PayloadIdentifier": "com.ccswitch.network-probe.test." + suffix,
         "PayloadDisplayName": name]
    }

    static func write(configurationPath: String, outputPath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
        guard let configuration = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              configuration["probeMode"] as? String == "proxy",
              let upstream = configuration["upstream"] as? String,
              (configuration["applicationPaths"] as? [String] ?? []).isEmpty else {
            throw URLError(.badURL)
        }
        _ = try Upstream(url: upstream)
        if let front = configuration["frontProxy"] as? String, !front.isEmpty {
            _ = try Upstream(url: front)
        }
        let applicationPath = "/Applications/CCSwitchEgressProbe.app"
        let providerPath = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/com.ccswitch.network-probe.provider.systemextension").path
        let (applicationIdentifier, applicationRequirement) = try signature(applicationPath)
        let (providerIdentifier, providerRequirement) = try signature(providerPath)
        guard applicationIdentifier == "com.ccswitch.egress-client-probe",
              providerIdentifier == "com.ccswitch.network-probe.provider" else {
            throw URLError(.noPermissionsToReadFile)
        }
        let vpnIdentifier = UUID().uuidString
        var vpn = payload("com.apple.vpn.managed.applayer", "vpn", "CC Switch 测试应用代理")
        vpn["VPNType"] = "VPN"
        vpn["VPNSubType"] = "com.ccswitch.network-probe"
        vpn["UserDefinedName"] = "CC Switch 测试应用代理"
        vpn["VPNUUID"] = vpnIdentifier
        vpn["OnDemandMatchAppEnabled"] = true
        vpn["VendorConfig"] = configuration
        vpn["VPN"] = [
            "RemoteAddress": "127.0.0.1", "AuthenticationMethod": "Password",
            "ProviderBundleIdentifier": providerIdentifier,
            "ProviderDesignatedRequirement": providerRequirement,
            "ProviderType": "app-proxy", "OnDemandEnabled": 1,
            "OnDemandRules": [["Action": "Connect"]]
        ] as [String: Any]
        var mapping = payload("com.apple.vpn.managed.appmapping", "mapping", "CC Switch 测试应用匹配")
        mapping["AppLayerVPNMapping"] = [[
            "Identifier": applicationIdentifier, "SigningIdentifier": applicationIdentifier,
            "DesignatedRequirement": applicationRequirement, "VPNUUID": vpnIdentifier
        ]]
        var profile = payload("Configuration", "profile", "CC Switch 测试应用代理")
        profile["PayloadScope"] = "User"
        profile["PayloadDescription"] = "仅配置 CCSwitchEgressProbe 验证程序的网络连接。"
        profile["PayloadContent"] = [vpn, mapping]
        let output = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        guard FileManager.default.createFile(atPath: outputPath, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw URLError(.cannotCreateFile)
        }
        try output.write(to: URL(fileURLWithPath: outputPath))
    }
}
