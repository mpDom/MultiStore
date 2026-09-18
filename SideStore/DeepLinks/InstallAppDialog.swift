//
//  InstallAppDialog.swift
//  SideStore
//
//  Created by Magesh K on 8/2/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit

@MainActor
public enum InstallAppDialog {
    
    public static func present(
        ipaURL: URL,
        from presentingViewController: UIViewController? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let rootVC = presentingViewController ?? UIApplication.shared.topViewController()
        guard let presentingVC = rootVC else {
            onCancel()
            return
        }
        
        let appName = ipaURL.deletingPathExtension().lastPathComponent
        
        let alert = UIAlertController(
            title: NSLocalizedString("Install App", comment: ""),
            message: String(format: NSLocalizedString("Would you like to install \"%@\"?", comment: ""), appName),
            preferredStyle: .alert
        )
        
        let installAction = UIAlertAction(title: NSLocalizedString("Install", comment: ""), style: .default) { _ in
            onConfirm()
        }
        
        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
            onCancel()
        }
        
        alert.addAction(installAction)
        alert.addAction(cancelAction)
        
        presentingVC.present(alert, animated: true)
    }
}
