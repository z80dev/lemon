import Foundation
import LemonBotKit

/// Keep support diagnostics separate from the sentence shown in the interface.
func humanErrorText(_ error: Error) -> String {
    let message: String
    if let backend = error as? BackendError {
        switch backend.failure.code {
        case "outcome_unknown": message = "We couldn't confirm this finished. Check its status before trying again."
        case "unauthorized", "unauthenticated": message = "Sign in again to continue."
        case "forbidden": message = "You don't have permission to do this. Ask the workspace owner."
        default: message = backend.failure.message
        }
    } else if let client = error as? ClientError {
        switch client {
        case .outcomeUnknown, .unresolvedMutation: message = "We couldn't confirm this finished. Check its status before trying again."
        case .offline: message = "You're offline. Reconnect before trying again. Nothing was queued."
        case .keychain: message = "Couldn't access your saved account. Unlock your Keychain or sign in again."
        case .http: message = "The server couldn't complete this request. Try again later."
        case .invalidFrame, .invalidCursor, .invalidBinary: message = "Couldn't load this update. Refresh and try again."
        case .invalidNonce, .invalidPath: message = "Couldn't prepare this action. Close this screen and try again."
        default: message = client.localizedDescription
        }
    } else if let network = error as? URLError {
        switch network.code {
        case .notConnectedToInternet, .networkConnectionLost: message = "You're offline. Check your internet connection and try again."
        case .timedOut: message = "The server took too long to respond. Check the connection and try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate: message = "Couldn't connect securely. Check the server address and certificate."
        default: message = "Couldn't reach the Lemon Bot server. Check the connection and try again."
        }
    } else if let localized = error as? LocalizedError, let description = localized.errorDescription {
        message = description
    } else {
        message = "Couldn't complete this action. Try again."
    }
    let diagnostics = error.localizedDescription
    return diagnostics == message ? message : message + "\nDetails: " + diagnostics
}

func pairingStatusLabel(_ state: String) -> String {
    switch state {
    case "preview": return "Ready to check"
    case "preview_ready": return "Ready to request connection"
    case "pending_approval": return "Waiting for approval on your Mac"
    case "claim_unknown": return "Request not confirmed. Check your request before trying again."
    case "completion_unknown": return "Connection not confirmed. Check your request."
    case "completing": return "Finishing connection"
    case "approved": return "Approved. Finish connecting on your iPhone."
    case "connected": return "Connected"
    case "denied": return "Connection denied"
    case "expired": return "Request expired. Create a new QR code."
    default: return "Not connected"
    }
}
