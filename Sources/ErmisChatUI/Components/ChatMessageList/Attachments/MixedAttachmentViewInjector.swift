//
// Copyright 2025 Ermis Inc.
//

import Foundation
import ErmisChat

/// The injector used to combine multiple types of attachment views.
open class MixedAttachmentViewInjector: CustomCellViewInjector {
    /// The registry of injectors associated with their attachment type, that support mixed attachment rendering.
    ///
    /// **Note:** It is an array and not a dictionary, since it defines the order of the rendering of the different types of attachments.
    /// In order to customise the order, this static property can be changed.
    ///
    /// By default, this is the order of how mixed attachments are rendered:
    ///
    ///     1. Images and Videos
    ///     2. Files
    ///     3. Voice Messages
    public static var injectorsRegistry: [(type: AttachmentType, injector: CustomCellViewInjector.Type)] = [
        (.video, GalleryAttachmentViewInjector.self),
        (.image, GalleryAttachmentViewInjector.self),
        (.file, FilesAttachmentViewInjector.self),
        (.voiceRecording, VoiceRecordingAttachmentViewInjector.self)
    ]

    // This property needs to be lazy so that we only create the injectors once.
    open lazy var injectors: [CustomCellViewInjector] = Self.injectors(for: contentView.content).map {
        $0.init(contentView)
    }

    public required init(_ contentView: MessageContentView) {
        super.init(contentView)
    }

    /// Register a custom attachment injector if the attachment can be mixed with other types of attachments.
    ///
    /// **Advanced:** You can use the `injectorsRegistry` property directly in case you want to change the default order
    /// of how different types of attachments are rendered.
    public static func register(_ type: AttachmentType, with injector: CustomCellViewInjector.Type) {
        injectorsRegistry.append((type, injector))
    }

    /// The mixed injectors for the given message.
    ///
    /// Given a message, it determines which injectors it should use to render the attachments.
    public static func injectors(for message: ChatMessage?) -> [CustomCellViewInjector.Type] {
        let injectorsForMessage = Self.injectorsRegistry
            .filter {
                message?.attachmentCounts.keys.contains($0.type) == true
            }

        var injectorsFound: Set<String> = []
        var injectorsWithoutDuplicates: [CustomCellViewInjector.Type] = []
        injectorsForMessage.map(\.injector).forEach { injector in
            let injectorId = String(describing: injector)
            if !injectorsFound.contains(injectorId) {
                injectorsWithoutDuplicates.append(injector)
                injectorsFound.insert(injectorId)
            }
        }

        return injectorsWithoutDuplicates
    }

    override open func contentViewDidLayout(options: MessageLayoutOptions) {
        injectors.forEach { $0.contentViewDidLayout(options: options) }
    }

    override open func contentViewDidcontentDidChanged() {
        injectors.forEach { $0.contentViewDidcontentDidChanged() }
    }

    override open func contentViewDidPrepareForReuse() {
        injectors.forEach { $0.contentViewDidPrepareForReuse() }
    }
}
