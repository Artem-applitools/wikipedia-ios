import CocoaLumberjackSwift

public enum RemoteNotificationsOperationsError: Error {
    case failureSettingUpModelController
}

class RemoteNotificationsOperationsController: NSObject {
    private let apiController: RemoteNotificationsAPIController
    private let modelController: RemoteNotificationsModelController?
    private let operationQueue: OperationQueue
    private let preferredLanguageCodesProvider: WMFPreferredLanguageInfoProvider
    private var isImporting = false
    private var isRefreshing = false
    private var importingCompletionBlocks: [(RemoteNotificationsOperationsError?) -> Void] = []
    
    var viewContext: NSManagedObjectContext? {
        return modelController?.viewContext
    }

    private var isLocked: Bool = false {
        didSet {
            if isLocked {
                stop()
            }
        }
    }

    required init(session: Session, configuration: Configuration, preferredLanguageCodesProvider: WMFPreferredLanguageInfoProvider) {
        apiController = RemoteNotificationsAPIController(session: session, configuration: configuration)
        var modelControllerInitializationError: Error?
        modelController = RemoteNotificationsModelController(&modelControllerInitializationError)
        if let modelControllerInitializationError = modelControllerInitializationError {
            DDLogError("Failed to initialize RemoteNotificationsModelController and RemoteNotificationsOperationsDeadlineController: \(modelControllerInitializationError)")
            isLocked = true
        }

        operationQueue = OperationQueue()
        
        self.preferredLanguageCodesProvider = preferredLanguageCodesProvider
        
        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(modelControllerDidLoadPersistentStores(_:)), name: RemoteNotificationsModelController.didLoadPersistentStoresNotification, object: nil)
    }
    
    func deleteLegacyDatabaseFiles() throws {
        modelController?.deleteLegacyDatabaseFiles()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func stop() {
        operationQueue.cancelAllOperations()
    }
    
    public func toggleReadStatus(viewNotification: RemoteNotification) {
        //TODO: Mark as Read operation that hits API and flips and saves local flag on managed object. For now just doing local part.
        modelController?.toggleReadStatus(viewNotification)
    }
    
    /// Kicks off operations to fetch and persist read and unread history of notifications from app languages, Commons, and Wikidata. Designed to fully import once per installation. Will not attempt if import is already in progress. Must be called from main thread.
    /// - Parameter completion: Block to run once operations have completed. Dispatched to main thread.
    func importNotificationsIfNeeded(_ completion: @escaping (RemoteNotificationsOperationsError?) -> Void) {
        
        assert(Thread.isMainThread)
        
        guard !isLocked else {
            assertionFailure("Failure setting up notifications core data stack.")
            completion(.failureSettingUpModelController)
            return
        }
        
        importingCompletionBlocks.append(completion)
        
        //Purposefully not calling completion block here, because we are tracking it in line above. It will be called when
        //currently running operation completes.
        guard !isImporting else {
            return
        }
        
        isImporting = true
        
        kickoffPagingOperations(operationType: RemoteNotificationsImportOperation.self) { [weak self] error in
            DispatchQueue.main.async {
                self?.isImporting = false
                self?.importingCompletionBlocks.forEach { completionBlock in
                    completionBlock(error)
                }

                self?.importingCompletionBlocks.removeAll()
            }
        }
    }
    
    /// Kicks off operations to fetch and persist any new read and unread notifications from app languages, Commons, and Wikidata. Will not attempt if importing or refreshing is already in progress. Must be called from main thread.
    /// - Parameter completion: Block to run once operations have completed. Dispatched to main thread.
    func refreshNotifications(_ completion: @escaping (RemoteNotificationsOperationsError?) -> Void) {
        
        assert(Thread.isMainThread)
        
        guard !isLocked else {
            assertionFailure("Failure setting up notifications core data stack.")
            completion(.failureSettingUpModelController)
            return
        }
        
        guard !isImporting && !isRefreshing else {
            completion(nil)
            return
        }
        
        isRefreshing = true
        
        kickoffPagingOperations(operationType: RemoteNotificationsRefreshOperation.self) { [weak self] error in
            DispatchQueue.main.async {
                self?.isRefreshing = false
                completion(error)
            }
        }
    }
    
    /// Method that instantiates the appropriate paging operations for fetching & persisting remote notifications and adds them to the operation queue. Must be called from main thread.
    /// - Parameters:
    ///   - operationType: RemoteNotificationsPagingOperation class to instantiate. Can be an Import or Refresh type.
    ///   - completion: Block to run after operations have completed.
    private func kickoffPagingOperations(operationType: RemoteNotificationsPagingOperation.Type, completion: @escaping (RemoteNotificationsOperationsError?) -> Void) {
        
        guard let modelController = modelController else {
            assertionFailure("Failure setting up notifications core data stack.")
            completion(.failureSettingUpModelController)
            return
        }
        
        let isImporting = operationType == RemoteNotificationsImportOperation.self
        
        preferredLanguageCodesProvider.getPreferredLanguageCodes({ [weak self] (preferredLanguageCodes) in
            
            guard let self = self else {
                return
            }

            var projects: [RemoteNotificationsProject] = preferredLanguageCodes.map { .language($0, nil) }
            projects.append(.commons)
            projects.append(.wikidata)
            
            let apiController: RemoteNotificationsAPIController = isImporting ? RemoteNotificationsTestingAPIController(session: self.apiController.session, configuration: self.apiController.configuration) : self.apiController
            let operations = projects.map { operationType.init(with: apiController, modelController: modelController, project: $0) }
            
            let completionOperation = BlockOperation {
                completion(nil)
            }
            
            for operation in operations {
                completionOperation.addDependency(operation)
            }
            
            self.operationQueue.addOperations(operations + [completionOperation], waitUntilFinished: false)
        })
    }

    // MARK: Notifications
    
    @objc private func modelControllerDidLoadPersistentStores(_ note: Notification) {
        if let object = note.object, let error = object as? Error {
            DDLogDebug("RemoteNotificationsModelController failed to load persistent stores with error \(error); stopping RemoteNotificationsOperationsController")
            isLocked = true
        } else {
            isLocked = false
        }
    }
}
