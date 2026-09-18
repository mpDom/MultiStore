//
//  AccountManager+Actions.swift
//  AltStore
//
//  App-layer account actions that require the signing/refresh pipeline (AppManager,
//  AuthenticationOperation). The data/credential facade lives in
//  AltStoreCore/Managers/AccountManager.swift; this extension adds the interactive operations.
//

import Foundation
import CoreData
import UIKit

import AltSign

extension AccountManager
{
    /// Add a new Apple account by presenting the sign-in UI, forcing a fresh login so a *new*
    /// Apple ID can be entered rather than silently re-authenticating the current account. The
    /// newly added account becomes the default account for new installs. Returns the resolved
    /// `Account` (a view-context object) on success.
    @discardableResult
    func addAccount(presentingViewController: UIViewController, completionHandler: @escaping (Result<Account, Error>) -> Void) -> Task<Void, Never>
    {
        let dbBackgroundContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let context = AppManager.shared.makeAuthenticatedContext(presentingViewController: presentingViewController, dbBackgroundContext: dbBackgroundContext)
        context.ignoresCachedCredentials = true

        return Task {
            do
            {
                let result = try await AuthManager.shared.authenticate(context: context, skipDeviceRegistration: false)
                let accountID = result.team.account.identifier
                await MainActor.run {
                    if let account = self.account(accountID, in: DatabaseManager.shared.viewContext)
                    {
                        completionHandler(.success(account))
                    }
                    else
                    {
                        completionHandler(.failure(OperationError.unknown()))
                    }
                }
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }

    /// Refresh every installed app signed by the given account, authenticating as that account.
    @discardableResult
    func refreshAccount(_ accountID: String, presentingViewController: UIViewController?, completionHandler: @escaping (Result<[String: Result<InstalledApp, Error>], Error>) -> Void = { _ in }) -> RefreshGroup
    {
        let apps = self.appsForAccount(accountID, in: DatabaseManager.shared.viewContext)

        let context = AppManager.shared.makeAuthenticatedContext(presentingViewController: presentingViewController)
        context.accountID = accountID
        let group = RefreshGroup(context: context)
        group.completionHandler = { results in
            completionHandler(.success(results))
        }

        // Nothing to refresh — complete through the group so any group-based observers finish too.
        guard !apps.isEmpty else {
            group.completionHandler?([:])
            return group
        }

        return AppManager.shared.refresh(apps, presentingViewController: presentingViewController, group: group)
    }

    /// Remove an account and its stored credentials on a background context.
    func removeAccount(_ accountID: String, completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            do
            {
                try self.deleteAccount(accountID, in: context)
                DispatchQueue.main.async { completionHandler(.success(())) }
            }
            catch
            {
                DispatchQueue.main.async { completionHandler(.failure(error)) }
            }
        }
    }

    /// Reassign an installed app to a different signing account and re-sign it with that account.
    func changeSigningAccount(for installedApp: InstalledApp, to accountID: String, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void)
    {
        let bundleIdentifier = installedApp.bundleIdentifier
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.performAndWait {
            guard self.assignAccount(accountID, toAppWithBundleIdentifier: bundleIdentifier, in: context) else {
                DispatchQueue.main.async { completionHandler(.failure(OperationError.appNotFound(name: installedApp.name))) }
                return
            }

            do { try context.save() }
            catch {
                DispatchQueue.main.async { completionHandler(.failure(error)) }
                return
            }

            DispatchQueue.main.async {
                // Re-sign with the newly-assigned account (inferred from the app's signingAccountID).
                let app = DatabaseManager.shared.viewContext.object(with: installedApp.objectID) as? InstalledApp ?? installedApp
                _ = AppManager.shared.resign(app, presentingViewController: presentingViewController, completionHandler: completionHandler)
            }
        }
    }
}
