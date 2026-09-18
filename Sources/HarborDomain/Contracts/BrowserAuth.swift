import Foundation

/// Browser presentation contract. Platform supplies the view; providers declare policy.
public struct BrowserAuthRequest: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case googlePlayEmbedded
        case systemOAuthPKCE
    }

    public var kind: Kind
    public var permittedHostSuffixes: [String]
    public var callbackScheme: String
    public var callbackHost: String?
    public var callbackPathPrefix: String

    public init(
        kind: Kind,
        permittedHostSuffixes: [String],
        callbackScheme: String,
        callbackHost: String? = nil,
        callbackPathPrefix: String = "/"
    ) {
        self.kind = kind
        self.permittedHostSuffixes = permittedHostSuffixes
        self.callbackScheme = callbackScheme
        self.callbackHost = callbackHost
        self.callbackPathPrefix = callbackPathPrefix
    }
}

public enum BrowserAuthValidator: Sendable {
    public static func isPermittedNavigation(url: URL, request: BrowserAuthRequest) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == request.callbackScheme.lowercased() {
            if let host = request.callbackHost {
                guard url.host?.lowercased() == host.lowercased() else { return false }
            }
            if request.callbackPathPrefix != "/" {
                guard url.path.hasPrefix(request.callbackPathPrefix) else { return false }
            }
            return true
        }
        guard scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return request.permittedHostSuffixes.contains { suffix in
            host == suffix.lowercased() || host.hasSuffix("." + suffix.lowercased())
        }
    }

    public static func validateCallback(url: URL, request: BrowserAuthRequest) throws {
        guard url.scheme?.lowercased() == request.callbackScheme.lowercased() else {
            throw HarborError.unauthorizedCallback(reason: "Callback scheme mismatch")
        }
        if let host = request.callbackHost, url.host?.lowercased() != host.lowercased() {
            throw HarborError.unauthorizedCallback(reason: "Callback host mismatch")
        }
        if request.callbackPathPrefix != "/", !url.path.hasPrefix(request.callbackPathPrefix) {
            throw HarborError.unauthorizedCallback(reason: "Callback path mismatch")
        }
    }
}

public enum ProcessArchitectureProbe: Sendable {
    public static var currentArchitectureString: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Best-effort Rosetta detection via sysctl; false when unknown.
    public static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0)
        return result == 0 && value == 1
    }
}
