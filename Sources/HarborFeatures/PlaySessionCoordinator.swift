import Foundation
import Observation

public enum PlaySessionStatus: Equatable, Sendable {
    case signedOut, signingIn, checking, signingOut
    case signedIn(email: String?, restored: Bool)
    case expired
    case unavailable(String)

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .signingIn, .checking, .signingOut: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .signedOut: return "Not signed in"
        case .signingIn: return "Signing in…"
        case .checking: return "Checking saved session…"
        case .signingOut: return "Signing out…"
        case .signedIn(_, let restored): return restored ? "Signed in · restored session" : "Signed in"
        case .expired: return "Sign-in expired"
        case .unavailable: return "Unable to verify"
        }
    }

    public var email: String? {
        if case .signedIn(let email, _) = self { return email }
        return nil
    }
}

struct GoogleSignInCredentials: Sendable {
    var cookies: [String: String]
    var email: String?
}

enum GoogleSignInResult: Sendable {
    case completed(GoogleSignInCredentials)
    case cancelled, timedOut
    case failed(String)
}

enum PlayValidationResult: Sendable {
    case verified(email: String?)
    case rejected
    case unavailable(String)
}

@MainActor
protocol PlaySessionBackend: AnyObject {
    func hasSavedCredentials() -> Bool
    func validate() async -> PlayValidationResult
    func signIn(fresh: Bool) async -> GoogleSignInResult
    func cancelSignIn()
    func accept(_ credentials: GoogleSignInCredentials) throws
    func clear() async throws
}

/// One owner for Google session truth. Persisted data is only a candidate;
/// neither a remembered email nor an old `.ready` account can sign a user in.
@MainActor
@Observable
public final class PlaySessionCoordinator {
    public private(set) var status: PlaySessionStatus = .signedOut
    public private(set) var lastSignInMessage: String?
    private let backend: any PlaySessionBackend
    private var checkedSavedSession = false
    private var generation = UUID()
    private var validationTask: Task<Void, Never>?

    init(backend: any PlaySessionBackend) { self.backend = backend }

    /// Schedules one background check; callers never await network work just
    /// to reload a view or launch an installed game.
    func restoreIfNeeded() {
        guard !checkedSavedSession else { return }
        checkedSavedSession = true
        guard backend.hasSavedCredentials() else { return }
        startValidation(restored: true)
    }

    public func retry() async {
        guard !status.isBusy else { return }
        checkedSavedSession = true
        guard backend.hasSavedCredentials() else { status = .signedOut; return }
        startValidation(restored: true)
        await validationTask?.value
    }

    func waitForValidation() async { await validationTask?.value }

    private func startValidation(restored: Bool) {
        let attempt = UUID()
        generation = attempt
        status = .checking
        validationTask = Task { [weak self] in
            guard let self else { return }
            let result = await backend.validate()
            guard !Task.isCancelled, generation == attempt else { return }
            switch result {
            case .verified(let email): status = .signedIn(email: email, restored: restored)
            case .rejected: status = .expired
            case .unavailable(let reason): status = .unavailable(reason)
            }
        }
    }

    public func signIn(fresh: Bool) async {
        guard !status.isBusy else { return }
        checkedSavedSession = true
        let previous = status
        let attempt = UUID()
        generation = attempt
        status = .signingIn
        lastSignInMessage = nil
        let result = await backend.signIn(fresh: fresh)
        guard generation == attempt else { return }
        switch result {
        case .completed(let credentials):
            guard let token = credentials.cookies["oauth_token"],
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status = .signedOut
                lastSignInMessage = "Sign-in was not completed. Please try again."
                return
            }
            do {
                try backend.accept(credentials)
                startValidation(restored: false)
                await validationTask?.value
            } catch {
                status = .unavailable("Could not save the Google session. Try signing in again.")
            }
        case .cancelled, .timedOut, .failed:
            status = previous.isSignedIn ? previous : .signedOut
            switch result {
            case .cancelled: lastSignInMessage = "Sign-in cancelled."
            case .timedOut: lastSignInMessage = "Sign-in timed out. Please try again."
            case .failed(let reason): lastSignInMessage = reason
            default: break
            }
        }
    }

    public func signOut() async {
        guard status != .signingOut else { return }
        generation = UUID()
        checkedSavedSession = true
        status = .signingOut
        lastSignInMessage = nil
        backend.cancelSignIn()
        validationTask?.cancel()
        // A validator may be completing an isolated credential exchange. Wait
        // for its cleanup before clearing stores so it cannot resurrect them.
        await validationTask?.value
        validationTask = nil
        do {
            try await backend.clear()
            status = .signedOut
        } catch {
            status = .unavailable("Some saved sign-in data could not be removed. Retry Sign out.")
        }
    }
}
