// MARK: – Notifications.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension Notification.Name {
    // Posted when any user preference is changed from the UI.
    // userInfo will contain: [key: "<preferenceKey>"]
    static let togglerPreferencesChanged =
        Notification.Name("com.toggler.preferencesChanged")
}
