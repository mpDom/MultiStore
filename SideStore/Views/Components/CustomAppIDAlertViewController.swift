//
//  CustomAppIDAlertViewController.swift
//  SideStore
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation

class AppendTeamIDCheckboxView: UIView {
    let checkboxButton = UIButton(type: .system)
    let label = UILabel()
    
    var isChecked: Bool = true {
        didSet {
            updateButtonImage()
            onToggle?(isChecked)
        }
    }
    
    var onToggle: ((Bool) -> Void)?
    
    init(isChecked: Bool = true) {
        self.isChecked = isChecked
        super.init(frame: .zero)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func updateButtonImage() {
        let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let imageName = isChecked ? "checkmark.circle.fill" : "circle"
        let image = UIImage(systemName: imageName, withConfiguration: configuration)
        checkboxButton.setImage(image, for: .normal)
    }
    
    private func setup() {
        checkboxButton.tintColor = .systemBlue
        checkboxButton.imageView?.contentMode = .scaleAspectFit
        checkboxButton.setContentHuggingPriority(.required, for: .horizontal)
        checkboxButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        checkboxButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            checkboxButton.widthAnchor.constraint(equalToConstant: 22),
            checkboxButton.heightAnchor.constraint(equalToConstant: 22)
        ])
        checkboxButton.addTarget(self, action: #selector(toggleCheckbox), for: .touchUpInside)
        
        label.text = NSLocalizedString("Append Team ID", comment: "")
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = .label
        label.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleCheckbox))
        label.addGestureRecognizer(tap)
        
        let stack = UIStackView(arrangedSubviews: [checkboxButton, label])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        
        updateButtonImage()
    }
    
    @objc func toggleCheckbox() {
        isChecked.toggle()
    }
}
