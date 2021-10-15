import CocoaLumberjackSwift

class RemoteNotificationsOperationsController: NSObject {
    private let apiController: RemoteNotificationsAPIController
    private let modelController: RemoteNotificationsModelController?
    private let operationQueue: OperationQueue
    private let preferredLanguageCodesProvider: WMFTestingPreferredLanguageInfoProvider
    private var isImporting = false
    private var isRefreshing = false
    
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

    required init(session: Session, configuration: Configuration, preferredLanguageCodesProvider: WMFTestingPreferredLanguageInfoProvider) {
        #if DEBUG
        apiController = RemoteNotificationsTestingAPIController(session: session, configuration: configuration)
        #else
        apiController = RemoteNotificationsAPIController(session: session, configuration: configuration)
        #endif
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
    
    func importNotificationsIfNeeded(primaryLanguageCompletion: @escaping () -> Void, allLanguagesCompletion: @escaping () -> Void) {
        
        assert(Thread.isMainThread)
        
        let exitEarly: () -> Void = {
            self.operationQueue.addOperation(primaryLanguageCompletion)
            self.operationQueue.addOperation(allLanguagesCompletion)
        }

        guard !isLocked,
              !isImporting else {
            exitEarly()
            return
        }
        
        //TODO: we should test how the app handles if the database fails to set up
        guard let modelController = modelController else {
            assertionFailure("Failure setting up notifications core data stack.")
            exitEarly()
            return
        }
        
        isImporting = true
        
        preferredLanguageCodesProvider.getTestingPreferredLanguageCodes({ [weak self] (preferredLanguageCodes) in
            
            guard let self = self else {
                return
            }

            var operations: [RemoteNotificationsImportOperation] = []
            
            var isPrimary = true
            for languageCode in preferredLanguageCodes {
                
                let project = RemoteNotificationsProject.language(languageCode, nil)
                let operation = RemoteNotificationsImportOperation(with: self.apiController, modelController: modelController, project: project, cookieDomain: self.cookieDomainForProject(project))
                
                //TODO: Probably shouldn't assume isPrimary is the first one, but that seems to be what
                //MWKLanguageLinkController's appLanguage does
                if isPrimary {
                    operation.completionBlock = primaryLanguageCompletion
                }
                
                operations.append(operation)
                isPrimary = false
            }
            
            let commonsProject = RemoteNotificationsProject.commons
            let commonsOperation = RemoteNotificationsImportOperation(with: self.apiController, modelController: modelController, project: commonsProject, cookieDomain: self.cookieDomainForProject(commonsProject))
            operations.append(commonsOperation)
            
            let wikidataProject = RemoteNotificationsProject.wikidata
            let wikidataOperation = RemoteNotificationsImportOperation(with: self.apiController, modelController: modelController, project: wikidataProject, cookieDomain: self.cookieDomainForProject(wikidataProject))
            operations.append(wikidataOperation)

            let completionOperation = BlockOperation { [weak self] in
                DispatchQueue.main.async {
                    self?.isImporting = false
                    allLanguagesCompletion()
                }
            }
            completionOperation.queuePriority = .veryHigh

            for operation in operations {
                completionOperation.addDependency(operation)
            }

            self.operationQueue.addOperations(operations + [completionOperation], waitUntilFinished: false)
        })
    }
    
    func refreshNotifications(_ completion: @escaping () -> Void) {
        
        assert(Thread.isMainThread)
        
        guard !isLocked,
              !isImporting,
              !isRefreshing else {
            self.operationQueue.addOperation(completion)
            return
        }
        
        guard let modelController = modelController else {
            assertionFailure("Failure setting up notifications core data stack.")
            self.operationQueue.addOperation(completion)
            return
        }
        
        self.isRefreshing = true
        
        preferredLanguageCodesProvider.getTestingPreferredLanguageCodes({ [weak self] (preferredLanguageCodes) in
            
            guard let self = self else {
                return
            }

            var projects: [RemoteNotificationsProject] = preferredLanguageCodes.map { .language($0, nil) }
            projects.append(.commons)
            projects.append(.wikidata)

            var operations: [RemoteNotificationsRefreshOperation] = []
            #if DEBUG
            operations = projects.map { RemoteNotificationsTestingRefreshOperation(with: self.apiController, modelController: modelController, project: $0, cookieDomain: self.cookieDomainForProject($0)) }
            #else
            operations = projects.map { RemoteNotificationsRefreshOperation(with: self.apiController, modelController: modelController, project: $0, cookieDomain: self.cookieDomainForProject($0)) }
            #endif
            
            let completionOperation = BlockOperation { [weak self] in
                DispatchQueue.main.async {
                    self?.isRefreshing = false
                    completion()
                }
            }
            
            completionOperation.queuePriority = .normal
            
            for operation in operations {
                completionOperation.addDependency(operation)
            }
            
            self.operationQueue.addOperations(operations + [completionOperation], waitUntilFinished: false)
        })
    }
    
    private func cookieDomainForProject(_ project: RemoteNotificationsProject) -> String {
        switch project {
        case .wikidata:
            return Configuration.current.wikidataCookieDomain
        case .commons:
            return Configuration.current.commonsCookieDomain
        default:
            return Configuration.current.wikipediaCookieDomain
        }
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
