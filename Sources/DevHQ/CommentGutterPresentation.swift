import AppKit
import Combine
import CodeEditSourceEditor
import SwiftUI

/// Identifies the editor document a comment coordinator serves.
struct CommentEditorContext: Equatable, Hashable {
    let documentID: UUID
    let fileURL: URL
    let isReadOnly: Bool
}

@MainActor
final class CommentEditorPresentation: ObservableObject {
    private(set) lazy var coordinator = CommentEditorCoordinator()

    func bind(context: CommentEditorContext?) {
        coordinator.bind(context: context, comments: CommentThreadsController.active)
    }
}

/// Draws review-comment gutter markers in a view injected above CodeEdit's
/// GutterView (the same technique as `DiffEditorCoordinator`), opens the
/// floating thread overlay on marker clicks, and reports the current text
/// selection for `devhq:add-comment`.
@MainActor
final class CommentEditorCoordinator: NSObject, @preconcurrency TextViewCoordinator {
    private weak var controller: TextViewController?
    private weak var markerView: CommentGutterMarkerView?
    private(set) weak var overlayView: NSView?
    private weak var comments: CommentThreadsController?
    private var context: CommentEditorContext?
    private var changeObservation: AnyCancellable?
    private var clickMonitor: Any?
    private var overlayThreadID: String?
    private var overlayCreated = false
    private var overlayInput = ""
    private var hasAppeared = false
    private var gutterFrameObserver: Any?

    var isReady: Bool {
        hasAppeared && controller != nil
    }

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
    }

    func controllerDidAppear(controller: TextViewController) {
        hasAppeared = true
        installMarkerView(in: controller)
        refreshMarkers()
        consumePendingCaret()
    }

    func textViewDidChangeText(controller: TextViewController) {
        refreshMarkers()
    }

    func destroy() {
        closeOverlay()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        if let gutterFrameObserver {
            NotificationCenter.default.removeObserver(gutterFrameObserver)
        }
        gutterFrameObserver = nil
        markerView?.removeFromSuperview()
        markerView = nil
        changeObservation = nil
        if let context {
            comments?.unregister(coordinator: self, documentID: context.documentID)
        }
        controller = nil
        hasAppeared = false
    }

    func bind(context: CommentEditorContext?, comments: CommentThreadsController?) {
        if let previous = self.context, previous.documentID != context?.documentID {
            self.comments?.unregister(coordinator: self, documentID: previous.documentID)
        }
        self.context = context
        self.comments = comments
        changeObservation = nil
        if let comments, let context {
            comments.register(coordinator: self, documentID: context.documentID)
            changeObservation = comments.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshMarkers() }
        }
        refreshMarkers()
        consumePendingCaret()
    }

    /// The current selection as a 1-based comment range, or nil when the
    /// selection is empty.
    func selectedRange() -> CommentRange? {
        guard let controller,
              let position = controller.cursorPositions.first(where: { $0.range.length > 0 }),
              let end = position.end else {
            return nil
        }
        return CommentRange(
            start: CommentPosition(line: position.start.line, col: position.start.column),
            end: CommentPosition(line: end.line, col: end.column)
        )
    }

    func moveCaret(line: Int, col: Int) {
        controller?.setCursorPositions(
            [CursorPosition(line: line, column: col)],
            scrollToVisible: true
        )
    }

    // MARK: - Markers

    func refreshMarkers() {
        guard let markerView else { return }
        let threads = context.flatMap { comments?.threads(forDocumentURL: $0.fileURL) } ?? []
        markerView.markers = threads.map {
            CommentGutterMarkerView.Marker(
                threadID: $0.id,
                line: $0.range.start.line,
                isResolved: $0.state == .resolved
            )
        }
        markerView.textViewController = controller
        markerView.needsDisplay = true
        if let overlayThreadID, comments?.thread(id: overlayThreadID) == nil {
            closeOverlay()
        }
    }

    private func installMarkerView(in controller: TextViewController) {
        guard markerView == nil,
              let gutter = firstSubview(of: GutterView.self, in: controller.scrollView) else {
            return
        }
        let markerView = CommentGutterMarkerView(frame: .zero)
        markerView.onSelectThread = { [weak self] threadID in
            self?.openOverlay(threadID: threadID, created: false)
        }
        gutterFrameObserver = installGutterMarkerStrip(markerView, tracking: gutter)
        self.markerView = markerView
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    private func consumePendingCaret() {
        guard isReady,
              let context,
              let caret = comments?.consumePendingCaret(for: context.documentID) else { return }
        moveCaret(line: caret.line, col: caret.col)
    }

    // MARK: - Overlay

    func openOverlay(threadID: String, created: Bool) {
        guard let controller,
              let comments,
              let thread = comments.thread(id: threadID) else { return }
        closeOverlay()

        overlayThreadID = threadID
        overlayCreated = created
        overlayInput = thread.state == .draft ? thread.firstMessage.body : ""

        let overlay = NSHostingView(
            rootView: CommentOverlayView(
                thread: thread,
                initialInput: overlayInput,
                onInputChange: { [weak self] input in
                    self?.overlayInput = input
                },
                onSave: { [weak self] input in
                    guard let self else { return }
                    self.closeOverlay()
                    self.comments?.commitOverlay(threadID: threadID, input: input)
                },
                onResolve: { [weak self] in
                    guard let self else { return }
                    self.closeOverlay()
                    self.comments?.resolveThread(id: threadID)
                },
                onCancel: { [weak self] input in
                    self?.cancelOverlay(input: input)
                }
            )
        )
        overlay.identifier = NSUserInterfaceItemIdentifier("comment-overlay:\(threadID)")
        overlay.translatesAutoresizingMaskIntoConstraints = true

        let container = controller.view
        let width = min(480, max(280, container.bounds.width - 32))
        let estimatedHeight = CGFloat(thread.messages.count) * 20 + 116
        let height = min(max(120, estimatedHeight), max(120, container.bounds.height - 24))
        overlay.frame = NSRect(
            x: min(max(16, anchorPoint(for: thread, in: container).x),
                   max(16, container.bounds.maxX - width - 16)),
            y: min(max(12, anchorPoint(for: thread, in: container).y),
                   max(12, container.bounds.maxY - height - 12)),
            width: width,
            height: height
        )
        overlay.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlayView = overlay
        comments.overlayWillOpen()
        installClickMonitor()
        overlay.window?.makeFirstResponder(overlay)
    }

    /// Where the overlay is anchored: just below the thread's start line when
    /// its position is known, otherwise near the top of the editor.
    private func anchorPoint(for thread: CommentThread, in container: NSView) -> NSPoint {
        guard let controller,
              let line = controller.textView.layoutManager.textLineForIndex(
                thread.range.start.line - 1
              ) else {
            return NSPoint(x: 24, y: container.isFlipped ? 18 : container.bounds.maxY - 18)
        }
        let pointInTextView = NSPoint(x: 0, y: line.yPos + line.height + 4)
        let converted = controller.textView.convert(pointInTextView, to: container)
        return NSPoint(x: 24, y: converted.y)
    }

    private func cancelOverlay(input: String) {
        guard let overlayThreadID else {
            closeOverlay()
            return
        }
        let created = overlayCreated
        closeOverlay()
        comments?.cancelOverlay(threadID: overlayThreadID, created: created, input: input)
    }

    func closeOverlay() {
        guard overlayView != nil else { return }
        overlayView?.removeFromSuperview()
        overlayView = nil
        overlayThreadID = nil
        overlayCreated = false
        comments?.overlayDidClose()
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            self?.handleOverlayEvent(event) ?? event
        }
    }

    func handleOverlayEvent(_ event: NSEvent) -> NSEvent? {
        guard let overlay = overlayView else { return event }

        switch event.type {
        case .leftMouseDown:
            guard event.window === overlay.window else {
                cancelOverlay(input: overlayInput)
                return event
            }
            let point = overlay.convert(event.locationInWindow, from: nil)
            if !overlay.bounds.contains(point) {
                cancelOverlay(input: overlayInput)
            }
            return event
        case .keyDown where event.window === overlay.window
            && (event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}"):
            cancelOverlay(input: overlayInput)
            return nil
        case .keyDown where event.window === overlay.window
            && (event.keyCode == 36 || event.keyCode == 76):
            let input = overlayInput
            if let threadID = overlayThreadID {
                closeOverlay()
                comments?.commitOverlay(threadID: threadID, input: input)
            }
            return nil
        case .keyDown where event.window === overlay.window
            && event.charactersIgnoringModifiers?.lowercased() == "r"
            && !event.modifierFlags.intersection([.command, .control]).isEmpty:
            if let overlayThreadID, comments?.thread(id: overlayThreadID)?.state == .open {
                closeOverlay()
                comments?.resolveThread(id: overlayThreadID)
                return nil
            }
            return event
        default:
            return event
        }
    }
}

@MainActor
final class CommentGutterMarkerView: NSView {
    struct Marker {
        let threadID: String
        let line: Int
        let isResolved: Bool
    }

    weak var textViewController: TextViewController?
    var markers: [Marker] = []
    var onSelectThread: ((String) -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        marker(at: point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        guard let marker = marker(at: convert(event.locationInWindow, from: nil)) else { return }
        onSelectThread?(marker.threadID)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let controller = textViewController else { return }

        for marker in markers {
            guard let rect = markerRect(for: marker, controller: controller),
                  rect.intersects(dirtyRect) else {
                continue
            }
            let color: NSColor = marker.isResolved ? .systemGray : .systemOrange
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func marker(at point: NSPoint) -> Marker? {
        guard point.x > 5, point.x <= 13, let controller = textViewController else { return nil }
        return markers.last { marker in
            markerRect(for: marker, controller: controller)?
                .insetBy(dx: -3, dy: -2)
                .contains(point) == true
        }
    }

    /// The comment bar sits just right of the diff markers, which occupy
    /// x 1...6 in `DiffGutterMarkerView`.
    private func markerRect(for marker: Marker, controller: TextViewController) -> NSRect? {
        guard marker.line > 0,
              let line = controller.textView.layoutManager.textLineForIndex(marker.line - 1) else {
            return nil
        }
        return NSRect(x: 8, y: line.yPos + 1, width: 3.5, height: max(6, line.height - 2))
    }
}
