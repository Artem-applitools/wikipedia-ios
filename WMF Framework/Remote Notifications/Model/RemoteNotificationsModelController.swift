import CocoaLumberjackSwift

public extension Notification.Name {
    static let NotificationsCenterContextDidSave = Notification.Name("NotificationsCenterContextDidSave")
    static let NotificationsCenterBadgeNeedsUpdate = Notification.Name("NotificationsCenterBadgeNeedsUpdate")
}

@objc public extension NSNotification {
    static let notificationsCenterContextDidSave = Notification.Name.NotificationsCenterContextDidSave
    static let notificationsCenterBadgeNeedsUpdate = Notification.Name.NotificationsCenterBadgeNeedsUpdate
}

final class RemoteNotificationsModelController: NSObject {
    
    enum LibraryKey: String {
        case completedImportFlags = "RemoteNotificationsCompletedImportFlags"
        case continueIdentifer = "RemoteNotificationsContinueIdentifier"
        case filterSettings = "RemoteNotificationsFilterSettings"
        
        func fullKeyForProject(_ project: RemoteNotificationsProject) -> String {
            if self == .filterSettings {
                assertionFailure("Shouldn't be using this key for filterSettings")
            }
            return "\(self.rawValue)-\(project.notificationsApiWikiIdentifier)"
        }
    }
    
    public static let didLoadPersistentStoresNotification = NSNotification.Name(rawValue: "ModelControllerDidLoadPersistentStores")
    
    //TODO: Look into removing this in the future (some legacy code still uses this)
    let legacyBackgroundContext: NSManagedObjectContext
    
    let viewContext: NSManagedObjectContext
    let persistentContainer: NSPersistentContainer

    enum InitializationError: Error {
        case unableToCreateModelURL(String, String, Bundle)
        case unableToCreateModel(URL, String)

        var localizedDescription: String {
            switch self {
            case .unableToCreateModelURL(let modelName, let modelExtension, let modelBundle):
                return "Couldn't find url for resource named \(modelName) with extension \(modelExtension) in bundle \(modelBundle); make sure you're providing the right name, extension and bundle"
            case .unableToCreateModel(let modelURL, let modelName):
                return "Couldn't create model with contents of \(modelURL); make sure \(modelURL) is the correct url for \(modelName)"
            }
        }
    }
    
    static let modelName = "RemoteNotifications"

    required init?(_ initializationError: inout Error?) {
        let modelName = RemoteNotificationsModelController.modelName
        let modelExtension = "momd"
        let modelBundle = Bundle.wmf
        guard let modelURL = modelBundle.url(forResource: modelName, withExtension: modelExtension) else {
            let error = InitializationError.unableToCreateModelURL(modelName, modelExtension, modelBundle)
            assertionFailure(error.localizedDescription)
            initializationError = error
            return nil
        }
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            let error = InitializationError.unableToCreateModel(modelURL, modelName)
            assertionFailure(error.localizedDescription)
            initializationError = error
            return nil
        }
        let container = NSPersistentContainer(name: modelName, managedObjectModel: model)
        let sharedAppContainerURL = FileManager.default.wmf_containerURL()
        let remoteNotificationsStorageURL = sharedAppContainerURL.appendingPathComponent("\(modelName).sqlite")

        let description = NSPersistentStoreDescription(url: remoteNotificationsStorageURL)
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { (storeDescription, error) in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: RemoteNotificationsModelController.didLoadPersistentStoresNotification, object: error)
            }
        }
        legacyBackgroundContext = container.newBackgroundContext()
        legacyBackgroundContext.name = "RemoteNotificationsLegacyBackgroundContext"
        legacyBackgroundContext.automaticallyMergesChangesFromParent = true
        legacyBackgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        viewContext = container.viewContext
        viewContext.name = "RemoteNotificationsViewContext"
        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        
        self.persistentContainer = container

        super.init()
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidLogOutNotification), name: WMFAuthenticationManager.didLogOutNotification, object: nil)
    }
    
    func deleteLegacyDatabaseFiles() {
        let modelName = Self.modelName
        let sharedAppContainerURL = FileManager.default.wmf_containerURL()
        let legacyStorageURL = sharedAppContainerURL.appendingPathComponent(modelName)
        do {
            try persistentContainer.persistentStoreCoordinator.destroyPersistentStore(at: legacyStorageURL, ofType: NSSQLiteStoreType, options: nil)
        } catch (let error) {
            DDLogError("Error with destroyPersistentStore for RemoteNotifications: \(error)")
        }
        
        let legecyJournalShmUrl = sharedAppContainerURL.appendingPathComponent("\(modelName)-shm")
        let legecyJournalWalUrl = sharedAppContainerURL.appendingPathComponent("\(modelName)-wal")
        
        do {
            try FileManager.default.removeItem(at: legacyStorageURL)
            try FileManager.default.removeItem(at: legecyJournalShmUrl)
            try FileManager.default.removeItem(at: legecyJournalWalUrl)
        } catch (let error) {
            DDLogError("Error deleting legacy RemoteNotifications database files: \(error)")
        }
    }
    
    @objc func handleDidLogOutNotification() {
        
        let batchDeleteBlock: (NSFetchRequest<NSFetchRequestResult>, NSManagedObjectContext) -> Void = { [weak self] (fetchRequest, backgroundContext) in
            
            guard let self = self else {
                return
            }
            
            let batchRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            batchRequest.resultType = .resultTypeObjectIDs
            
            do {
                let result = try backgroundContext.execute(batchRequest) as? NSBatchDeleteResult
                let objectIDArray = result?.result as? [NSManagedObjectID]
                let changes: [AnyHashable : Any] = [NSDeletedObjectsKey : objectIDArray as Any]
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [self.viewContext])
            } catch (let error) {
                DDLogError("Error batch deleting notifications upon logout: \(error)")
            }
        }
        
        let backgroundContext = newBackgroundContext()
        let request: NSFetchRequest<NSFetchRequestResult> = RemoteNotification.fetchRequest()
        let libraryRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest<NSFetchRequestResult>(entityName: "WMFKeyValue")
        
        //batch delete all notification managed objects from Core Data
        batchDeleteBlock(request, backgroundContext)
        
        //batch delete all library values from Core Data
        batchDeleteBlock(libraryRequest, backgroundContext)
        
        //remove notifications from shared cache (referenced by the NotificationsService extension)
        let sharedCache = SharedContainerCache<PushNotificationsCache>.init(pathComponent: .pushNotificationsCache, defaultCache: { PushNotificationsCache(settings: .default, notifications: []) })
        var cache = sharedCache.loadCache()
        cache.notifications = []
        cache.currentUnreadCount = 0
        sharedCache.saveCache(cache)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    typealias ResultHandler = (Set<RemoteNotification>?) -> Void
    
    public func newBackgroundContext() -> NSManagedObjectContext {
        let backgroundContext = persistentContainer.newBackgroundContext()
        backgroundContext.name = "RemoteNotificationsBackgroundContext"
        backgroundContext.automaticallyMergesChangesFromParent = true
        backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return backgroundContext
    }
    
    var numberOfUnreadNotifications: Int? {
        let fetchRequest: NSFetchRequest<RemoteNotification> = RemoteNotification.fetchRequest()
        fetchRequest.predicate = unreadNotificationsPredicate
        return try? viewContext.count(for: fetchRequest)
    }

    public func createNewNotifications(moc: NSManagedObjectContext, notificationsFetchedFromTheServer: Set<RemoteNotificationsAPIController.NotificationsResult.Notification>, completion: @escaping () -> Void) throws {
        moc.perform {
            for notification in notificationsFetchedFromTheServer {
                self.createNewNotification(moc: moc, notification: notification)
            }

            self.save(moc: moc)
            NotificationCenter.default.post(name: Notification.Name.NotificationsCenterBadgeNeedsUpdate, object: nil)
            completion()
        }
    }

    // Reminder: Methods that access managedObjectContext should perform their operations
    // inside the perform(_:) or the performAndWait(_:) methods.
    // https://developer.apple.com/documentation/coredata/using_core_data_in_the_background
    private func createNewNotification(moc: NSManagedObjectContext, notification: RemoteNotificationsAPIController.NotificationsResult.Notification) {
        guard let date = notification.date else {
            assertionFailure("Notification should have a date")
            return
        }

        let isRead = notification.readString == nil ? NSNumber(booleanLiteral: false) : NSNumber(booleanLiteral: true)
        let _ = moc.wmf_create(entityNamed: "RemoteNotification",
                                                withKeysAndValues: [
                                                    "wiki": notification.wiki,
                                                    "id": notification.id,
                                                    "key": notification.key,
                                                    "typeString": notification.type,
                                                    "categoryString" : notification.category,
                                                    "section" : notification.section,
                                                    "date": date,
                                                    "utcUnixString": notification.timestamp.utcunix,
                                                    "titleFull": notification.title?.full,
                                                    "titleNamespace": notification.title?.namespace,
                                                    "titleNamespaceKey": notification.title?.namespaceKey,
                                                    "titleText": notification.title?.text,
                                                    "agentId": notification.agent?.id,
                                                    "agentName": notification.agent?.name,
                                                    "isRead" : isRead,
                                                    "revisionID": notification.revisionID,
                                                    "messageHeader": notification.message?.header,
                                                    "messageBody": notification.message?.body,
                                                    "messageLinks": notification.message?.links])
    }

    // MARK: Mark as read
    
    public func markAllAsRead(moc: NSManagedObjectContext, project: RemoteNotificationsProject, completion: @escaping () -> Void) {
        moc.perform {
            let unreadPredicate = self.unreadNotificationsPredicate
            let wikiPredicate = NSPredicate(format: "wiki == %@", project.notificationsApiWikiIdentifier)
            let compoundPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [unreadPredicate, wikiPredicate])
            self.notifications(with: compoundPredicate, moc: moc) { notifications in
                guard let notifications = notifications,
                      !notifications.isEmpty else {
                    completion()
                    return
                }
                
                notifications.forEach { notification in
                    notification.isRead = true
                }
                
                self.save(moc: moc)
                NotificationCenter.default.post(name: Notification.Name.NotificationsCenterBadgeNeedsUpdate, object: nil)
                completion()
            }
        }
        
    }
    
    public func markAllAsSeen(moc: NSManagedObjectContext, project: RemoteNotificationsProject, completion: @escaping () -> Void) {
        moc.perform {
            let unseenPredicate = self.unseenNotificationsPredicate
            
            // TODO: create a method that returns this to avoid code repetition?
            let wikiPredicate = NSPredicate(format: "wiki == %@", project.notificationsApiWikiIdentifier)
            let compoundPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [unseenPredicate, wikiPredicate])
            
            self.notifications(with: compoundPredicate, moc: moc) { notifications in
                guard let notifications = notifications,
                      !notifications.isEmpty else {
                          completion()
                          return
                      }
                notifications.forEach { notifications in
                    notifications.isSeen = true
                }
            }
            self.save(moc: moc)
            completion()
        }
    }

    public func markAsReadOrUnread(moc: NSManagedObjectContext, identifierGroups: Set<RemoteNotification.IdentifierGroup>, shouldMarkRead: Bool, completion: @escaping () -> Void) {
        
        processNotifications(moc: moc, identifierGroups: identifierGroups, handler: { (notification) in
            notification.isRead = shouldMarkRead
        }, completion: {
            NotificationCenter.default.post(name: Notification.Name.NotificationsCenterBadgeNeedsUpdate, object: nil)
            completion()
        })
    }
    
    public func wikisWithUnreadNotifications(moc: NSManagedObjectContext, completion: @escaping ([String]) -> Void) {
        return wikis(moc: moc, predicate: unreadNotificationsPredicate, completion: completion)
    }
    
    public func wikisWithUnseenNotifications(moc: NSManagedObjectContext, completion: @escaping ([String]) -> Void) {
        return wikis(moc: moc, predicate: unseenNotificationsPredicate, completion: completion)
    }

    private func processNotifications(moc: NSManagedObjectContext, identifierGroups: Set<RemoteNotification.IdentifierGroup>,  handler: @escaping (RemoteNotification) -> Void, completion: @escaping () -> Void) {
        let keys = identifierGroups.compactMap { $0.key }
        moc.perform {
            let fetchRequest: NSFetchRequest<RemoteNotification> = RemoteNotification.fetchRequest()
            let predicate = NSPredicate(format: "key IN %@", keys)
            fetchRequest.predicate = predicate
            guard let notifications = try? moc.fetch(fetchRequest) else {
                return
            }
            notifications.forEach { notification in
                handler(notification)
            }
            self.save(moc: moc)
            completion()
        }
    }
    
    private func notifications(with predicate: NSPredicate? = nil, moc: NSManagedObjectContext, completion: ResultHandler) {
        let fetchRequest: NSFetchRequest<RemoteNotification> = RemoteNotification.fetchRequest()
        fetchRequest.predicate = predicate
        guard let notifications = try? moc.fetch(fetchRequest) else {
            completion(nil)
            return
        }
        completion(Set(notifications))
    }
    
    func wikis(moc: NSManagedObjectContext, predicate: NSPredicate?, completion: @escaping ([String]) -> Void) {
        moc.perform {
            guard let entityName = RemoteNotification.entity().name else {
                return
            }

            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
            fetchRequest.predicate = predicate
            fetchRequest.resultType = .dictionaryResultType
            fetchRequest.propertiesToFetch = ["wiki"]
            fetchRequest.returnsDistinctResults = true
            guard let dictionaries = (try? moc.fetch(fetchRequest)) as? [[String: String]] else {
                completion([])
                return
            }
            
            let results = dictionaries.flatMap { $0.values }

            completion(results)
        }
    }
    
    private var unreadNotificationsPredicate: NSPredicate {
        return NSPredicate(format: "isRead == %@", NSNumber(value: false))
    }
    
    private var unseenNotificationsPredicate: NSPredicate {
        return NSPredicate(format: "isSeen == %@", NSNumber(value: false))
    }

    private func save(moc: NSManagedObjectContext) {
        if moc.hasChanges {
            do {
                try moc.save()
                NotificationCenter.default.post(name: Notification.Name.NotificationsCenterContextDidSave, object: nil)
            } catch let error {
                DDLogError("Error saving RemoteNotificationsModelController managedObjectContext: \(error)")
            }
        }
    }
    
    //MARK: Notifications Center Filter
    func getFilterSettingsFromLibrary() -> NSDictionary? {
        return libraryValue(forKey: LibraryKey.filterSettings.rawValue) as? NSDictionary
    }
    
    func setFilterSettingsToLibrary(dictionary: NSDictionary?) {
        setLibraryValue(dictionary, forKey: LibraryKey.filterSettings.rawValue)
    }
    
    //MARK: WMFLibraryValue Helpers
    //TODO: Cache this (see EventLoggingService as an example)
    
    func libraryValue(forKey key: String) -> NSCoding? {
        var result: NSCoding? = nil
        let backgroundContext = newBackgroundContext()
        backgroundContext.performAndWait {
            result = backgroundContext.wmf_keyValue(forKey: key)?.value
        }
        
        return result
    }
    
    func setLibraryValue(_ value: NSCoding?, forKey key: String) {
        let backgroundContext = newBackgroundContext()
        backgroundContext.perform {
            backgroundContext.wmf_setValue(value, forKey: key)
            do {
                try backgroundContext.save()
            } catch let error {
                DDLogError("Error saving RemoteNotifications backgroundContext for library keys: \(error)")
            }
        }
    }
}
