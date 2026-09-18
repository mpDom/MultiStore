//
//  UserCustomizationOperation.swift
//  SideStore
//
//  Created by Magesh K on 30/07/26.
//  Copyright © 2026 AltStore. All rights reserved.
//


import Foundation
final class UserCustomizationOperation: BasePipelineOperation<InstallAppOperationContext, String?>, @unchecked Sendable {

    override func execute(parentProgress: Progress?) async throws -> String? {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[UserCustomizationOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[UserCustomizationOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)

        guard UserDefaults.standard.customizeAppId else {
            self.setProgress(100)
            return nil
        }

        let handler = context.handler.userCustomizationHandler

        let initialBundleID = context.targetBundleIdentifier
        self.setProgress(40)
        
        guard let result = try await handler.resolveBundleIDOverride(initialBundleID: initialBundleID) else {
            throw OperationError.cancelled
        }
        
        context.appendTeamID = result.appendTeamID
        if result.customID != context.bundleIdentifier {
            context.customBundleIdentifier = result.customID
        } else {
            context.customBundleIdentifier = nil
        }

        
        self.setProgress(100)
        return context.targetBundleIdentifier
    }
}
