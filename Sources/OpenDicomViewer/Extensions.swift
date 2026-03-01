// Extensions.swift
// OpenDicomViewer
//
// Utility extensions used throughout the app.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
