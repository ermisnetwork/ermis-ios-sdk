//
// Copyright 2025 Ermis Inc.
//

import UIKit

/// Helper component to map image results.
struct ImageResultsMapper {
    let results: [Result<UIImage, Error>]

    init(results: [Result<UIImage, Error>]) {
        self.results = results
    }

    /// Replace errors with placeholder images.
    ///
    /// - Parameter placeholderImages: The placeholder images.
    /// - Returns: Returns an array of UIImages without errors.
    func mapErrors(with placeholderImages: [UIImage]) -> [UIImage] {
        var placeholderImages = placeholderImages
        return mapErrors { _ in 
            guard !placeholderImages.isEmpty else { return nil }
            return placeholderImages.removeFirst()
        }
    }
    
    /// Replace errors with placeholder images.
    ///
    /// - Parameter provider: The placeholder image provider. Returning nil will skip the result with a failure.
    ///
    /// - Returns: Returns an array of UIImages without errors.
    func mapErrors(with provider: (Int) -> UIImage?) -> [UIImage] {
        results.enumerated().compactMap { (index, result) in
            switch result {
            case let .success(image):
                return image
            case .failure:
                return provider(index)
            }
        }
    }
}
