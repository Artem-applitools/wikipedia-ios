/// LegacyCollectionViewUpdater handles UICollectionView updates via performBatchUpdates
@available(iOS, deprecated: 13.0)
class LegacyCollectionViewUpdater<T: NSFetchRequestResult>: NSObject, CollectionViewUpdater, NSFetchedResultsControllerDelegate {
    
    let fetchedResultsController: NSFetchedResultsController<T>
    let collectionView: UICollectionView
    var isSpringAnimationEnabled: Bool = false
    var sectionChanges: [WMFSectionChange] = []
    var objectChanges: [WMFObjectChange] = []
    weak var delegate: CollectionViewUpdaterDelegate?
    
    var isGranularUpdatingEnabled: Bool = true
    
    required init(fetchedResultsController: NSFetchedResultsController<T>, collectionView: UICollectionView) {
        self.fetchedResultsController = fetchedResultsController
        self.collectionView = collectionView
        super.init()
        self.fetchedResultsController.delegate = self
    }
    
    deinit {
        self.fetchedResultsController.delegate = nil
    }
    
    public func performFetch() {
        do {
            try fetchedResultsController.performFetch()
        } catch let error {
            assert(false)
            DDLogError("Error fetching \(String(describing: fetchedResultsController.fetchRequest.predicate)) for \(String(describing: self.delegate)): \(error)")
        }
        sectionCounts = fetchSectionCounts()
        collectionView.reloadData()
    }
    
    // MARK: Updates
    
    @objc func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        sectionChanges = []
        objectChanges = []
    }
    
    @objc func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange anObject: Any, at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?) {
        let objectChange = WMFObjectChange()
        objectChange.fromIndexPath = indexPath
        objectChange.toIndexPath = newIndexPath
        objectChange.type = type
        objectChanges.append(objectChange)
    }
    
    @objc func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange sectionInfo: NSFetchedResultsSectionInfo, atSectionIndex sectionIndex: Int, for type: NSFetchedResultsChangeType) {
        let sectionChange = WMFSectionChange()
        sectionChange.sectionIndex = sectionIndex
        sectionChange.type = type
        sectionChanges.append(sectionChange)
    }
    
    private var previousSectionCounts: [Int] = []
    private var sectionCounts: [Int] = []
    private func fetchSectionCounts() -> [Int] {
        let sections = fetchedResultsController.sections ?? []
        return sections.map { $0.numberOfObjects }
    }
    
    @objc func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        previousSectionCounts = sectionCounts
        sectionCounts = fetchSectionCounts()
        
        delegate?.collectionViewUpdater(self, willUpdate: collectionView)
        defer {
            delegate?.collectionViewUpdater(self, didUpdate: self.collectionView)
        }

        guard isGranularUpdatingEnabled else {
            collectionView.reloadData()
            return
        }
        
        var sectionDelta = 0
        var objectsInSectionDelta = 0
        var forceReload = false
        
        for sectionChange in sectionChanges {
            switch sectionChange.type {
            case .delete:
                guard sectionChange.sectionIndex < previousSectionCounts.count else {
                    forceReload = true
                    break
                }
                sectionDelta -= 1
            case .insert:
                sectionDelta += 1
                objectsInSectionDelta += sectionCounts[sectionChange.sectionIndex]
            default:
                break
            }
        }
        
        for objectChange in objectChanges {
            switch objectChange.type {
            case .delete:
                guard let fromIndexPath = objectChange.fromIndexPath,
                    fromIndexPath.section < previousSectionCounts.count,
                    fromIndexPath.item < previousSectionCounts[fromIndexPath.section] else {
                    forceReload = true
                    break
                }
                
                // there seems to be a very specific bug about deleting the item at index path 0,2 when there are 3 items in the section ¯\_(ツ)_/¯
                if fromIndexPath.section == 0 && fromIndexPath.item == 2 && previousSectionCounts[0] == 3 {
                    forceReload = true
                    break
                }

            default:
                break
            }
        }
        
        let sectionCountsMatch = (previousSectionCounts.count + sectionDelta) == sectionCounts.count
        guard !forceReload, sectionCountsMatch, objectChanges.count < 1000 && sectionChanges.count < 10 else { // reload data for invalid changes & larger changes
            collectionView.reloadData()
            delegate?.collectionViewUpdater(self, didUpdate: self.collectionView)
            return
        }

        guard isSpringAnimationEnabled else {
            self.performBatchUpdates()
            return
        }
        
        UIView.animate(withDuration: 0.8, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: .allowUserInteraction, animations: {
            self.performBatchUpdates()
        })
    }
    
    func performBatchUpdates() {
        let collectionView = self.collectionView
        collectionView.performBatchUpdates({
            DDLogDebug("=== WMFBU BATCH UPDATE START \(String(describing: self.delegate)) ===")
            for objectChange in objectChanges {
                switch objectChange.type {
                case .delete:
                    if let fromIndexPath = objectChange.fromIndexPath {
                        DDLogDebug("WMFBU object delete: \(fromIndexPath)")
                        collectionView.deleteItems(at: [fromIndexPath])
                    } else {
                        assert(false, "unhandled delete")
                        DDLogError("Unhandled delete: \(objectChange)")
                    }
                case .insert:
                    if let toIndexPath = objectChange.toIndexPath {
                        DDLogDebug("WMFBU object insert: \(toIndexPath)")
                        collectionView.insertItems(at: [toIndexPath])
                    } else {
                        assert(false, "unhandled insert")
                        DDLogError("Unhandled insert: \(objectChange)")
                    }
                case .move:
                    if let fromIndexPath = objectChange.fromIndexPath, let toIndexPath = objectChange.toIndexPath {
                        DDLogDebug("WMFBU object move delete: \(fromIndexPath)")
                        collectionView.deleteItems(at: [fromIndexPath])
                        DDLogDebug("WMFBU object move insert: \(toIndexPath)")
                        collectionView.insertItems(at: [toIndexPath])
                    } else {
                        assert(false, "unhandled move")
                        DDLogError("Unhandled move: \(objectChange)")
                    }
                    break
                case .update:
                    if let updatedIndexPath = objectChange.toIndexPath ?? objectChange.fromIndexPath {
                        collectionView.reloadItems(at: [updatedIndexPath])
                    } else {
                        assert(false, "unhandled update")
                        DDLogDebug("WMFBU unhandled update: \(objectChange)")
                    }
                @unknown default:
                    break
                }
            }
            
            for sectionChange in sectionChanges {
                switch sectionChange.type {
                case .delete:
                    DDLogDebug("WMFBU section delete: \(sectionChange.sectionIndex)")
                    collectionView.deleteSections(IndexSet(integer: sectionChange.sectionIndex))
                case .insert:
                    DDLogDebug("WMFBU section insert: \(sectionChange.sectionIndex)")
                    collectionView.insertSections(IndexSet(integer: sectionChange.sectionIndex))
                default:
                    DDLogDebug("WMFBU section update: \(sectionChange.sectionIndex)")
                    collectionView.reloadSections(IndexSet(integer: sectionChange.sectionIndex))
                }
            }
            DDLogDebug("=== WMFBU BATCH UPDATE END ===")
        }) { (finished) in
            self.delegate?.collectionViewUpdater(self, didUpdate: collectionView)
        }
    }
    
}
