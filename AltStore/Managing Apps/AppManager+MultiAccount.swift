//
//  AppManager+MultiAccount.swift
//  AltStore
//
//  Multi-account signing: partitions refreshes by the Apple account that signs each app and
//  infers which account a single-app operation must authenticate as. Kept apart from
//  AppManager.swift so the upstream orchestration (PipelineRunner) stays untouched.
//

import Foundation
import UIKit
import CoreData

extension AppManager
{
    /// The signing account to authenticate for a batch of operations, inferred from their apps.
    ///
    /// Returns an account identifier only when every installed-app operation resolves to the *same*
    /// account and that account has usable stored credentials; otherwise `nil` (fall back to the
    /// default/global credentials). Operations whose app isn't an `InstalledApp` (e.g. installing a
    /// brand-new app) are ignored, so new installs continue to use the default account.
    static func inferredAccountID(for operations: [AppOperation]) -> String?
    {
        var accountIDs = Set<String>()

        for operation in operations
        {
            guard let installedApp = operation.app as? InstalledApp else { continue }

            if let resolvedID = Self.resolvedSigningAccountID(of: installedApp)
            {
                accountIDs.insert(resolvedID)
            }
        }

        guard accountIDs.count == 1, let accountID = accountIDs.first, Keychain.shared.hasCredentials(forAccount: accountID) else { return nil }
        return accountID
    }

    /// Partition installed apps by their resolved signing account identifier, preserving order.
    /// Apps with no explicit signing account fall back to the default (active) account so they
    /// are grouped together rather than each spawning a separate authentication.
    static func partitionAppsByAccount(_ apps: [InstalledApp]) async -> [(accountID: String?, apps: [InstalledApp])]
    {
        let defaultAccountID = await DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            DatabaseManager.shared.activeAccount(in: context)?.identifier
        }

        var order = [String?]()
        var buckets = [String?: [InstalledApp]]()

        for app in apps
        {
            let key = Self.resolvedSigningAccountID(of: app) ?? defaultAccountID
            if buckets[key] == nil
            {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(app)
        }

        return order.map { (accountID: $0, apps: buckets[$0] ?? []) }
    }

    /// Run each account's apps in its own authenticated `RefreshGroup`, merging results, progress
    /// and installation callbacks back into `aggregateGroup`. Each child authenticates
    /// independently, so a failure in one account is isolated to that account's apps.
    func refresh(partitions: [(accountID: String?, apps: [InstalledApp])],
                 handler: PipelineExecutionHandler,
                 presentingViewController: UIViewController?,
                 aggregateGroup: RefreshGroup) async
    {
        let lock = NSLock()
        var merged = [String: Result<InstalledApp, Error>]()

        let pendingUnitCount = Int64(100 / max(partitions.count, 1))

        await withTaskGroup(of: Void.self) { taskGroup in
            for partition in partitions
            {
                let childContext = self.makeAuthenticatedContext(presentingViewController: presentingViewController)
                childContext.accountID = partition.accountID
                let childGroup = RefreshGroup(context: childContext, sharedContext: aggregateGroup.sharedContext)

                // Forward the SideStore self-install callback (used for the background-refresh
                // notification) up to the aggregate group.
                childGroup.beginInstallationHandler = { [weak aggregateGroup, weak childGroup] installedApp in
                    if let error = childGroup?.context.error
                    {
                        aggregateGroup?.context.error = error
                    }
                    aggregateGroup?.beginInstallationHandler?(installedApp)
                }

                childGroup.completionHandler = { results in
                    lock.withLock {
                        for (bundleID, result) in results
                        {
                            merged[bundleID] = result
                            aggregateGroup.set(result, forAppWithBundleIdentifier: bundleID)
                        }
                    }
                }

                aggregateGroup.progress.addChild(childGroup.progress, withPendingUnitCount: pendingUnitCount)

                let apps = partition.apps
                taskGroup.addTask {
                    do {
                        _ = try await self.pipelineRunner.perform(apps.map { .refresh($0) }, handler: handler, group: childGroup)
                    } catch {
                        childGroup.context.error = error
                        let results = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleIdentifier, Result<InstalledApp, Error>.failure(error)) })
                        childGroup.completionHandler?(results)
                    }
                }
            }
        }

        // Fire the aggregate completion exactly once, after every child has finished — a
        // background refresh resumes a continuation here, so a double-invocation would be fatal.
        let snapshot = lock.withLock { merged }
        await MainActor.run {
            aggregateGroup.completionHandler?(snapshot)
        }
    }

    private static func resolvedSigningAccountID(of installedApp: InstalledApp) -> String?
    {
        var resolvedID: String?
        if let context = installedApp.managedObjectContext
        {
            context.performAndWait { resolvedID = installedApp.resolvedSigningAccountID }
        }
        else
        {
            resolvedID = installedApp.resolvedSigningAccountID
        }
        return resolvedID
    }
}
