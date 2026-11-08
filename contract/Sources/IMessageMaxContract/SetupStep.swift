import Foundation

/// The permissions the companion's Permissions page lists, in order. Each
/// title is the name macOS gives the setting. Diagnose fixes name a permission
/// by its title, so the server and the app must spell it the same way.
public enum SetupStep: String, Sendable, CaseIterable {
  case backgroundActivity, fullDiskAccess, contacts, automation

  public var title: String {
    switch self {
    case .backgroundActivity: "Background activity"
    case .fullDiskAccess: "Full Disk Access"
    case .contacts: "Contacts"
    case .automation: "Automation"
    }
  }
}
