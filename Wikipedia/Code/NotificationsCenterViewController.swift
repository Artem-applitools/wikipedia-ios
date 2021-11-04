import UIKit

@objc
final class NotificationsCenterViewController: ViewController {

    // MARK: - Properties

    var notificationsView: NotificationsCenterView {
        return view as! NotificationsCenterView
    }

    let viewModel: NotificationsCenterViewModel
    
    typealias DataSource = UICollectionViewDiffableDataSource<NotificationsCenterSection, NotificationsCenterCellViewModel>
    typealias Snapshot = NSDiffableDataSourceSnapshot<NotificationsCenterSection, NotificationsCenterCellViewModel>
    private var dataSource: DataSource?

    private let snapshotUpdateQueue = DispatchQueue(label: "org.wikipedia.notificationscenter.snapshotUpdateQueue", qos: .userInteractive)
    
    private let refreshControl = UIRefreshControl()
    
    fileprivate lazy var cellPanGestureRecognizer = UIPanGestureRecognizer()
    fileprivate var activelyPannedCellIndexPath: IndexPath?

    // MARK: - Lifecycle

    @objc
    init(theme: Theme, viewModel: NotificationsCenterViewModel) {
        self.viewModel = viewModel
        super.init(theme: theme)
        viewModel.delegate = self
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NotificationsCenterView(frame: UIScreen.main.bounds)
        scrollView = notificationsView.collectionView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        notificationsView.apply(theme: theme)

        title = CommonStrings.notificationsCenterTitle
        setupBarButtons()
        
        notificationsView.collectionView.delegate = self
        setupRefreshControl()
        setupDataSource()
        //TODO: Revisit and enable importing empty states in a delayed manner to avoid flashing.
        //configureEmptyState(isEmpty: true, subheaderText: NotificationsCenterView.EmptyOverlayStrings.checkingForNotifications)
        viewModel.fetchFirstPage()
        
        notificationsView.collectionView.addGestureRecognizer(cellPanGestureRecognizer)
        cellPanGestureRecognizer.addTarget(self, action: #selector(userDidPanCell(_:)))
        cellPanGestureRecognizer.delegate = self
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        //temp commenting out so we can demonstrate refreshing only through pull to refresh.
        //viewModel.refreshNotifications()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            notificationsView.collectionView.reloadData()
        }
    }

	// MARK: - Configuration

    fileprivate func setupBarButtons() {
        enableToolbar()
        setToolbarHidden(false, animated: false)
        
        let filtersButton = UIBarButtonItem(title: "Filters", style: .plain, target: self, action: #selector(userDidTapFilterButton))

		navigationItem.rightBarButtonItems = [filtersButton, editButtonItem]
        isEditing = false
	}
    
    @objc func userDidTapFilterButton() {
            let filtersVC = NotificationsCenterFilterViewController()
            filtersVC.delegate = self
            present(filtersVC, animated: true, completion: nil)
        }

	// MARK: - Public
    
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        
        notificationsView.collectionView.allowsMultipleSelection = editing
        deselectCells()
        reconfigureCells()
    }


    // MARK: - Themable

    override func apply(theme: Theme) {
        super.apply(theme: theme)

        notificationsView.apply(theme: theme)
        notificationsView.collectionView.reloadData()
    }
}

//MARK: Private

private extension NotificationsCenterViewController {
    func setupRefreshControl() {
        notificationsView.collectionView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refresh(_:)), for: .valueChanged)
    }
    
    @objc private func refresh(_ sender: Any) {
        viewModel.refreshNotifications {
            self.refreshControl.endRefreshing()
        }
    }
    
    func setupDataSource() {
        dataSource = DataSource(
        collectionView: notificationsView.collectionView,
        cellProvider: { [weak self] (collectionView, indexPath, viewModel) ->
            NotificationsCenterCell? in

            guard let self = self,
                  let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NotificationsCenterCell.reuseIdentifier, for: indexPath) as? NotificationsCenterCell else {
                return nil
            }
            cell.configure(viewModel: viewModel, theme: self.theme, isEditing: self.isEditing)
            cell.delegate = self
            return cell
        })
    }
    
    func applySnapshot(cellViewModels: [NotificationsCenterCellViewModel], animatingDifferences: Bool = true) {
        
        guard let dataSource = dataSource else {
            return
        }
        
        snapshotUpdateQueue.async {
            var snapshot = Snapshot()
            snapshot.appendSections([.main])
            snapshot.appendItems(cellViewModels)
            dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
        }
    }
    
    func configureEmptyState(isEmpty: Bool, subheaderText: String = "") {
        notificationsView.updateEmptyOverlay(visible: isEmpty, headerText: NotificationsCenterView.EmptyOverlayStrings.noUnreadMessages, subheaderText: subheaderText)
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = !isEmpty }
    }
    
    /// TODO: Use this to determine selected view models when in editing mode. We will send to NotificationsCenterViewModel for marking as read/unread when
    /// the associated toolbar button is pressed.
    /// - Returns:View models that represent cells in the selected state.
    func selectedCellViewModels() -> [NotificationsCenterCellViewModel] {
        let selectedIndexes = notificationsView.collectionView.indexPathsForSelectedItems?.map { $0.item } ?? []
        let currentSnapshot = dataSource?.snapshot()
        let viewModels = currentSnapshot?.itemIdentifiers ?? []
        let selectedViewModels = selectedIndexes.compactMap { viewModels.count > $0 ? viewModels[$0] : nil }
        return selectedViewModels
    }
    
    func deselectCells() {
        notificationsView.collectionView.indexPathsForSelectedItems?.forEach {
            notificationsView.collectionView.deselectItem(at: $0, animated: false)
        }
    }
    
    /// Calls cell configure methods again without instantiating a new cell.
    /// - Parameter viewModels: Cell view models whose associated cells you want to configure again. If nil, method uses available items in the snapshot (or visible cells) to configure.
    func reconfigureCells(with viewModels: [NotificationsCenterCellViewModel]? = nil) {
        
        if #available(iOS 15.0, *) {
            snapshotUpdateQueue.async {
                if var snapshot = self.dataSource?.snapshot() {
                    let viewModelsToUpdate = viewModels ?? snapshot.itemIdentifiers
                    snapshot.reconfigureItems(viewModelsToUpdate)
                    self.dataSource?.apply(snapshot, animatingDifferences: false)
                }
            }
        } else {
            
            let cellsToReconfigure: [NotificationsCenterCell]
            if let viewModels = viewModels {
                
                //Limit visible cells only by those we're interested in reconfiguring. Note cell must already contain reference to view model in order for this reconfiguration to go through.
                cellsToReconfigure = notificationsView.collectionView.visibleCells.compactMap { cell in
                    
                    guard let notificationsCell = cell as? NotificationsCenterCell,
                          let cellViewModel = notificationsCell.viewModel else {
                        return nil
                    }
                    
                    return viewModels.contains(cellViewModel) ? notificationsCell : nil
                }
            } else {
                cellsToReconfigure = notificationsView.collectionView.visibleCells as? [NotificationsCenterCell] ?? []
            }
            
            cellsToReconfigure.forEach { cell in
                cell.configure(theme: theme, isEditing: isEditing)
            }
        }
    }
}

// MARK: - NotificationCenterViewModelDelegate

extension NotificationsCenterViewController: NotificationCenterViewModelDelegate {
    func cellViewModelsDidChange(cellViewModels: [NotificationsCenterCellViewModel]) {
        if let firstViewModel = cellViewModels.first {
            notificationsView.updateCellHeightIfNeeded(viewModel: firstViewModel, isEditing: isEditing)
        }
        
        configureEmptyState(isEmpty: cellViewModels.isEmpty)
        applySnapshot(cellViewModels: cellViewModels, animatingDifferences: true)
    }
    
    func reloadCellWithViewModelIfNeeded(_ viewModel: NotificationsCenterCellViewModel) {
        reconfigureCells(with: [viewModel])
    }
}

extension NotificationsCenterViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        
        print("👀indexPath item: \(indexPath.item)")
        
        guard let dataSource = dataSource else {
            return
        }
        
        let count = dataSource.collectionView(collectionView, numberOfItemsInSection: indexPath.section)
        let isLast = indexPath.row == count - 1
        if isLast {
            viewModel.fetchNextPage()
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        if isEditing {
            return true
        }
        
        return false
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if !isEditing {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
    }
}

extension NotificationsCenterViewController: NotificationsCenterCellDelegate {
    func userDidTapSecondaryActionForCellIdentifier(id: String) {
        //TODO
    }
    
    func toggleReadStatus(viewModel: NotificationsCenterCellViewModel) {
        self.viewModel.toggleReadStatus(cellViewModel: viewModel)
    }
}

extension NotificationsCenterViewController: NotificationsCenterFilterViewControllerDelegate {
    func tappedToggleFilterButton() {
        viewModel.toggledFilter()
    }
}

// MARK: - Cell Swipe Actions

@objc extension NotificationsCenterViewController: UIGestureRecognizerDelegate {

    /// Only allow cell pan gesture if user's horizontal cell panning behavior seems intentional
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == cellPanGestureRecognizer {
            let panVelocity = cellPanGestureRecognizer.velocity(in: notificationsView.collectionView)
            if abs(panVelocity.x) > abs(panVelocity.y) {
                return true
            }
        }

        return false
    }

    @objc fileprivate func userDidPanCell(_ gestureRecognizer: UIPanGestureRecognizer) {
        switch gestureRecognizer.state {
        case .began:
            let touchPosition = gestureRecognizer.location(in: notificationsView.collectionView)
            guard let cellIndexPath = notificationsView.collectionView.indexPathForItem(at: touchPosition) else {
                gestureRecognizer.state = .ended
                break
            }

            activelyPannedCellIndexPath = cellIndexPath
        case .ended:
            userDidSwipeCell(indexPath: activelyPannedCellIndexPath)
            activelyPannedCellIndexPath = nil
        default:
            return
        }
    }

    /// This will be removed in the final implementation
    fileprivate func userDidSwipeCell(indexPath: IndexPath?) {
        /*
        guard let indexPath = indexPath, let cellViewModel = viewModel.cellViewModel(indexPath: indexPath) else {
            return
        }

        let alertController = UIAlertController(title: cellViewModel.headerText, message: cellViewModel.bodyText, preferredStyle: .actionSheet)

        let firstAction = UIAlertAction(title: "Action 1", style: .default)
        let secondAction = UIAlertAction(title: "Action 2", style: .default)
        let thirdAction = UIAlertAction(title: "Action 3", style: .default)
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)

        alertController.addAction(firstAction)
        alertController.addAction(secondAction)
        alertController.addAction(thirdAction)
        alertController.addAction(cancelAction)

        if let popoverController = alertController.popoverPresentationController, let cell = notificationsView.collectionView.cellForItem(at: indexPath) {
            popoverController.sourceView = cell
            popoverController.sourceRect = CGRect(x: cell.bounds.midX, y: cell.bounds.midY, width: 0, height: 0)
        }

        present(alertController, animated: true, completion: nil)
        */
    }

}
