import SwiftUI
import UIKit

/// Native interactive movement handles lifting, insertion previews, scrolling and cancellation.
struct IDEHomeGrid: UIViewControllerRepresentable {
    let apps: [IDEHomeApp]
    @Binding var isArranging: Bool
    let content: (IDEHomeApp) -> AnyView
    let label: (IDEHomeApp) -> String
    let selectedLanguage: ProgrammingLanguage
    let select: (IDEHomeApp) -> Void
    let move: (IDEHomeApp, Int) -> Void

    func makeUIViewController(context: Context) -> IDEHomeGridController {
        IDEHomeGridController()
    }

    func updateUIViewController(_ controller: IDEHomeGridController, context: Context) {
        controller.update(apps: apps, arranging: isArranging, selectedLanguage: selectedLanguage,
                          content: content, label: label, select: select, move: move,
                          beginArranging: { isArranging = true })
    }

    static func dismantleUIViewController(_ controller: IDEHomeGridController, coordinator: ()) {
        controller.cancelMovement()
    }
}

@MainActor
final class IDEHomeGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let layout = UICollectionViewFlowLayout()
    private lazy var grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
    private var apps: [IDEHomeApp] = []
    private var arranging = false
    private var moving = false
    private var lastWidth: CGFloat = 0
    private var selectedLanguage = ProgrammingLanguage.c
    private var content: (IDEHomeApp) -> AnyView = { _ in AnyView(EmptyView()) }
    private var label: (IDEHomeApp) -> String = { $0.title }
    private var select: (IDEHomeApp) -> Void = { _ in }
    private var move: (IDEHomeApp, Int) -> Void = { _, _ in }
    private var beginArranging: () -> Void = {}

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "app")
        grid.showsVerticalScrollIndicator = false
        grid.alwaysBounceVertical = true
        grid.contentInsetAdjustmentBehavior = .never
        grid.accessibilityIdentifier = "ide-home-grid"
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.topAnchor.constraint(equalTo: view.topAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hold.minimumPressDuration = 0.4
        hold.cancelsTouchesInView = true
        grid.addGestureRecognizer(hold)
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged),
                                              name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(suspendArrangement),
                                              name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if grid.bounds.width != lastWidth {
            cancelMovement()
            lastWidth = grid.bounds.width
            layout.invalidateLayout()
        }
    }

    func update(apps: [IDEHomeApp], arranging: Bool, selectedLanguage: ProgrammingLanguage,
                content: @escaping (IDEHomeApp) -> AnyView, label: @escaping (IDEHomeApp) -> String,
                select: @escaping (IDEHomeApp) -> Void, move: @escaping (IDEHomeApp, Int) -> Void,
                beginArranging: @escaping () -> Void) {
        loadViewIfNeeded()
        self.content = content; self.label = label; self.select = select; self.move = move
        self.beginArranging = beginArranging; self.selectedLanguage = selectedLanguage
        if !arranging { cancelMovement() }
        self.arranging = arranging
        grid.contentInset = UIEdgeInsets(top: 20, left: 20, bottom: arranging ? 80 : 24, right: 20)
        hold.minimumPressDuration = arranging ? 0.15 : 0.4
        // The data source updates synchronously on a successful drop. Avoid reloads
        // during movement, which would tear down UIKit's lifted item and preview.
        if self.apps != apps && !moving {
            self.apps = apps
            grid.reloadData()
        } else if !moving {
            for cell in grid.visibleCells {
                if let path = grid.indexPath(for: cell) { configure(cell, app: self.apps[path.item]) }
            }
        }
        updateWiggles()
    }

    func cancelMovement() {
        guard moving else { return }
        grid.cancelInteractiveMovement()
        moving = false
    }

    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let path = grid.indexPathForItem(at: gesture.location(in: grid)),
                  grid.beginInteractiveMovementForItem(at: path) else { return }
            moving = true
            arranging = true
            beginArranging()
            AppHaptics.tap()
            updateWiggles()
        case .changed:
            if moving { grid.updateInteractiveMovementTargetPosition(gesture.location(in: grid)) }
        case .ended:
            if moving { grid.endInteractiveMovement(); moving = false }
        case .cancelled, .failed:
            cancelMovement()
        default: break
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { apps.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "app", for: indexPath)
        configure(cell, app: apps[indexPath.item])
        return cell
    }

    private func configure(_ cell: UICollectionViewCell, app: IDEHomeApp) {
        cell.backgroundColor = .clear
        let tile = content(app)
        cell.contentConfiguration = UIHostingConfiguration {
            tile.allowsHitTesting(false).accessibilityHidden(true)
        }.margins(.all, 0)
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = label(app)
        cell.accessibilityIdentifier = app.accessibilityID
        cell.accessibilityTraits = app.language == selectedLanguage ? [.button, .selected] : [.button]
        cell.accessibilityHint = arranging ? "Move using the actions, then tap Done." : "Hold and drag to rearrange."
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Move earlier") { [weak self] _ in self?.accessibleMove(app, offset: -1) ?? false },
            UIAccessibilityCustomAction(name: "Move later") { [weak self] _ in self?.accessibleMove(app, offset: 1) ?? false }
        ]
        setWiggle(cell)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard !arranging, !moving else { return }
        let app = apps[indexPath.item]
        AppHaptics.play(app.language == nil ? .tap : .select)
        select(app)
    }

    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool { true }

    func collectionView(_ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let app = apps.remove(at: sourceIndexPath.item)
        apps.insert(app, at: destinationIndexPath.item)
        move(app, destinationIndexPath.item)
        AppHaptics.select()
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let available = collectionView.bounds.width - collectionView.contentInset.left - collectionView.contentInset.right
        return CGSize(width: max(1, (available - 32) / 3), height: 130)
    }

    private func accessibleMove(_ app: IDEHomeApp, offset: Int) -> Bool {
        guard !moving, let source = apps.firstIndex(of: app), apps.indices.contains(source + offset) else { return false }
        arranging = true
        beginArranging()
        let destination = source + offset
        apps.remove(at: source); apps.insert(app, at: destination)
        move(app, destination)
        grid.moveItem(at: IndexPath(item: source, section: 0), to: IndexPath(item: destination, section: 0))
        AppHaptics.select()
        UIAccessibility.post(notification: .announcement, argument: "\(app.title), position \(destination + 1) of \(apps.count)")
        return true
    }

    @objc private func suspendArrangement() {
        cancelMovement()
        arranging = false
        updateWiggles()
    }

    @objc private func reduceMotionChanged() { updateWiggles() }
    private func updateWiggles() { grid.visibleCells.forEach(setWiggle) }
    private func setWiggle(_ cell: UICollectionViewCell) {
        let layer = cell.contentView.layer
        guard arranging && !UIAccessibility.isReduceMotionEnabled else {
            layer.removeAnimation(forKey: "rearranging")
            return
        }
        guard layer.animation(forKey: "rearranging") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = -0.025
        animation.toValue = 0.025
        animation.duration = 0.14
        animation.autoreverses = true
        animation.repeatCount = .infinity
        layer.add(animation, forKey: "rearranging")
    }
}
