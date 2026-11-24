import Foundation

extension GameHost {
    /// Quality is presentation policy; changing it must not cancel pointer or hinge input.
    func configureRendering(_ configuration: GameRenderConfiguration?, monitor: GameRenderMonitor?,
                            presentation: GamePresentationSource?) {
        let sourceChanged = requestedPresentationSource !== presentation
        let changed = renderConfiguration != configuration || renderMonitor !== monitor || sourceChanged
        guard changed || (presentation != nil && activePresentationSource == nil) else { return }
        renderingRevision &+= 1
        let revision = renderingRevision
        renderConfiguration = configuration; renderMonitor = monitor
        if configuration != nil || monitor != nil || presentation != nil { hasAdvancedRendering = true }
        if sourceChanged {
            let old = activePresentationSource
            requestedPresentationSource = presentation
            activePresentationSource = nil
            old?.detach(owner: presentationOwner)
            guard renderingRevision == revision else { return }
        }
        activatePresentationSource()
        guard renderingRevision == revision else { return }
        nativeView?.configurePresentation()
        nativeView?.synchronizeRendering()
    }

    func activatePresentationSource() {
        guard activePresentationSource == nil, let requestedPresentationSource,
              requestedPresentationSource.attach(owner: presentationOwner) else { return }
        activePresentationSource = requestedPresentationSource
        requestedPresentationSource.setPublicationValidator(owner: presentationOwner) { [weak self] in
            guard let self, self.isPresentationActive else { return false }
            guard let view = self.nativeView else { return true }
            return view.window != nil && view.isNativeSurfaceVisible
        }
    }

    func suspendPresentationSource() {
        activePresentationSource?.suspend(owner: presentationOwner)
    }

    func releasePresentationSource() {
        let old = activePresentationSource
        activePresentationSource = nil
        old?.detach(owner: presentationOwner)
    }
}
