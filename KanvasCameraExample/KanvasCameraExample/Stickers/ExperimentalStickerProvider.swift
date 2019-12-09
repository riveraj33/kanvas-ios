//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Foundation
import UIKit
import KanvasCamera

/// Constants for ExperimentalStickerProvider
private struct Constants {
    static let resourceName: String = "stickers"
    static let resourceExtension: String = "json"
}

/// Class that obtains the stickers from the stickers file in the example app
public final class ExperimentalStickerProvider: StickerProvider {
    
    private weak var delegate: StickerProviderDelegate?
    
    // MARK: - StickerProvider Protocol
    
    public init(session: TMSession?) {
        // Session is not necessary for this provider implementation.
    }
    
    public func setDelegate(delegate: StickerProviderDelegate) {
        self.delegate = delegate
    }
    
    /// Gets the collection of stickers types
    public func getStickerTypes() {
        let data = getData()
        
        guard let providers = data["providers"] as? NSArray,
            let kanvasProvider = providers.firstObject as? Dictionary<String, Any>,
            let baseUrl = kanvasProvider["base_url"] as? String,
            let stickerList = data["stickers"] as? NSArray else {
                delegate?.didLoadStickerTypes([])
                return
        }
        
        var stickerTypes: [StickerType] = []
        
        stickerList.forEach { element in
            if let stickerItem = element as? Dictionary<String, Any>,
                let keyword = stickerItem["keyword"] as? String,
                let thumbUrl = stickerItem["thumb_url"] as? String,
                let count = stickerItem["count"] as? Int {
                stickerTypes.append(ExperimentalStickerType(baseUrl: baseUrl, keyword: keyword, thumbUrl: thumbUrl, count: count))
            }
        }
        
        delegate?.didLoadStickerTypes(stickerTypes)
    }
    
    // MARK: - Private utilities
    
    /// Creates a dictionary from the stickers JSON file
    private func getData() -> Dictionary<String, AnyObject> {
        if let path = Bundle(for: ExperimentalStickerProvider.self).path(forResource: "\(Constants.resourceName)", ofType: Constants.resourceExtension) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                let jsonResult = try JSONSerialization.jsonObject(with: data, options: .mutableLeaves)
                if let jsonResult = jsonResult as? Dictionary<String, AnyObject> {
                    return jsonResult
                }
            }
            catch {
                print("Error loading \(Constants.resourceName).\(Constants.resourceExtension)")
            }
        }
        
        return Dictionary<String, AnyObject>()
    }
}
