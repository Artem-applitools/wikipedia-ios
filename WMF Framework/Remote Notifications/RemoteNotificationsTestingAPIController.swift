
import Foundation

class RemoteNotificationsTestingAPIController: RemoteNotificationsAPIController {
    
    var continueCounts: [String: Int] = [:]
    let internalCountQueue = DispatchQueue.init(label: "RemoteNotificationsTestingAPIController.internalCountQueue")
    
    private func writeContinueCounts(key: String, value: Int) {
        internalCountQueue.async {
            self.continueCounts[key] = value
        }
    }
    
    private func readContinueCounts(key: String) -> Int? {
        internalCountQueue.sync {
            return self.continueCounts[key]
        }
    }
    
    override func getAllNotifications(from project: RemoteNotificationsProject, needsCrossWikiSummary: Bool = false, filter: Query.Filter = .none, continueId: String?, fromRefresh: Bool = false, completion: @escaping (RemoteNotificationsAPIController.NotificationsResult.Query.Notifications?, Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            
            //simulate time it takes to return from network
            sleep(UInt32(Int.random(in: 0...2)))
            
            let randomTotal = fromRefresh ? Int.random(in: 0...1) : 50
            
            print("🔵API CONTROLLER: \(project) - random total: \(randomTotal)")
            
            var continueID: String?
            if let count = self.readContinueCounts(key: project.notificationsApiWikiIdentifier) {
                self.writeContinueCounts(key: project.notificationsApiWikiIdentifier, value: count + 1)
                continueID = "continueID" + String(count + 1)
                if count > 13 {
                    continueID = nil
                }
            } else {
                continueID = "continueID" + String(2)
                self.writeContinueCounts(key: project.notificationsApiWikiIdentifier, value: 2)
            }
            
            if continueID != nil {
                print("🔵API CONTROLLER: \(project) - continue paging with \(continueID)")
            } else {
                print("🔵API CONTROLLER: \(project) - end paging")
            }
            
            var individualNotifications = self.randomlyGenerateNotifications(totalCount: randomTotal, project: project, fromRefresh: fromRefresh)
            
            if needsCrossWikiSummary {
                let crossWikiNotification = RemoteNotificationsAPIController.NotificationsResult.Notification(forCrossWikiSummary: true)
                individualNotifications.append(crossWikiNotification)
            }
            
            let notifications = RemoteNotificationsAPIController.NotificationsResult.Query.Notifications(list: individualNotifications, continueId: continueID)
            
            completion(notifications, nil)
        }
    }
    
    override func request<T: Decodable>(project: RemoteNotificationsProject?, queryParameters: Query.Parameters?, method: Session.Request.Method = .get, completion: @escaping (T?, URLResponse?, Error?) -> Void) {
        
        DispatchQueue.global(qos: .userInitiated).async {
            //simulate time it takes to return from network
            sleep(UInt32(Int.random(in: 0...2)))
            
            completion(nil, nil, nil)
        }
    }
    
    private func randomlyGenerateNotifications(totalCount: Int, project: RemoteNotificationsProject, fromRefresh: Bool) -> [RemoteNotificationsAPIController.NotificationsResult.Notification] {
        var result: [RemoteNotificationsAPIController.NotificationsResult.Notification] = []
        var loopNumber = 0
        while loopNumber < totalCount {
            let randomNotification = RemoteNotificationsAPIController.NotificationsResult.Notification.random(project: project, fromRefresh: fromRefresh)
            result.append(randomNotification)
            loopNumber = loopNumber + 1
        }
        
        return result
    }
}

fileprivate extension RemoteNotificationsAPIController.NotificationsResult.Notification {
    static func random(project: RemoteNotificationsProject, fromRefresh: Bool) -> RemoteNotificationsAPIController.NotificationsResult.Notification {
        return RemoteNotificationsAPIController.NotificationsResult.Notification(testing: true, project: project, fromRefresh: fromRefresh)
    }
    
    init(forCrossWikiSummary: Bool) {
        self.wiki = "enwiki"
        self.type = "foreign"
        self.id = "-1"
        self.sources = [
            "testwiki": ["title": "Test Wikipedia"],
            "frwiki": ["title": "French Wikipedia"],
            "zhwiki": ["title": "Chinese Wikipedia"],
            "eswiki": ["title": "Spanish Wikipedia"],
            "enwikibooks": ["title": "English Wikibooks"],
            "eswiktionary": ["title": "Spanish Wiktionary"],
            "dewikiquote": ["title": "German Wikiquote"],
            "ptwikisource": ["title": "Portuguese Wikisource"],
            "arwikinews": ["title": "Arabic Wikinews"],
            "enwikiversity": ["title": "English Wikiversity"],
            "plwikivoyage": ["title": "Polish Wikivoyage"],
            "mediawikiwiki": ["title": "Mediawiki"],
            "specieswiki": ["title": "Wikispecies"]
        ]
        
        self.section = ""
        
        self.category = ""
        
        self.timestamp = Timestamp(testing: true, fromRefresh: false, project: RemoteNotificationsProject.commons)
        self.title = nil
        self.agent = nil
        
        self.readString = nil
       
        self.message = nil
        self.revisionID = nil
    }
    
    init(testing: Bool, project: RemoteNotificationsProject, fromRefresh: Bool) {
        
        
        let randomCategoryAndTypeIDs: [(String, String)] = [
            ("edit-user-talk", "edit-user-talk"),
            ("mention", "mention"),
            ("mention", "mention-summary"),
            ("mention-success", "mention-success"),
            ("mention-failure", "mention-failure"),
            ("mention-failure", "mention-failure-too-many"),
            ("reverted", "reverted"),
            ("user-rights", "user-rights"),
            ("page-review", "pagetriage-mark-as-reviewed"),
            ("article-linked", "page-linked"),
            ("wikibase-action", "page-connection"),
            ("emailuser", "emailuser"),
            ("edit-thank", "edit-thank"),
            ("cx", "cx-first-translation"),
            ("cx", "cx-tenth-translation"),
            ("thank-you-edit", "thank-you-edit"),
            ("system-noemail", "welcome"),
            ("login-fail", "login-fail-new"),
            ("login-fail", "login-fail-known"),
            ("login-success", "login-success"),
            ("system", "anything1"),
            ("system-noemail", "anything2"),
            ("system-emailonly", "anything3"),
            ("anything4", "anything5")
        ]
        
        let section = ["message", "alert"]
        
        self.wiki = project.notificationsApiWikiIdentifier
        
        let identifier = UUID().uuidString
        self.id = identifier
        
        self.section = section.randomElement()!
        
        let randomCategoryAndType = randomCategoryAndTypeIDs.randomElement()!
        self.category = randomCategoryAndType.0
        self.type = randomCategoryAndType.1
        
        let timestamp = Timestamp(testing: true, fromRefresh: fromRefresh, project: project)
        self.timestamp = timestamp
        self.title = Title(testing: true, randomCategoryAndType: randomCategoryAndType)
        self.agent = Agent(testing: true, randomCategoryAndType: randomCategoryAndType, project: project)
        
        let isRead = Bool.random()
        self.readString = isRead ? "isRead" : nil
       
        self.message = Message(testing: true, identifier: identifier)
        self.revisionID = nil
        self.sources = nil
    }
}

fileprivate extension RemoteNotificationsAPIController.NotificationsResult.Notification.Timestamp {
    init(testing: Bool, fromRefresh: Bool, project: RemoteNotificationsProject) {
        let today = Date()
        let day = TimeInterval(60 * 60 * 24)
        let year = day * 365
        let twentyYearsAgo = Date(timeIntervalSinceNow: year * 20)
        let yesterday = Date(timeIntervalSinceNow: day)
        let randomTimeInterval = fromRefresh ? TimeInterval.random(in: today.timeIntervalSinceNow...yesterday.timeIntervalSinceNow) : TimeInterval.random(in: today.timeIntervalSinceNow...twentyYearsAgo.timeIntervalSinceNow)
        let randomDate = Date(timeIntervalSinceNow: -randomTimeInterval)
        let dateString8601 = DateFormatter.wmf_iso8601().string(from: randomDate)
        let unixTimeInterval = randomDate.timeIntervalSince1970
        self.utciso8601 = dateString8601
        self.utcunix = String(unixTimeInterval)
    }
}

fileprivate extension RemoteNotificationsAPIController.NotificationsResult.Notification.Title {
    init(testing: Bool, randomCategoryAndType: (String, String)) {
        
        switch randomCategoryAndType {
        case ("edit-user-talk", "edit-user-talk"):
            self.full = "User talk:Tsevener"
            self.namespace = "User_talk"
            self.namespaceKey = 3
            self.text = "Tsevener"
            return
        default:
            let random = Int.random(in: 1...2)
            switch random {
            case 1:
                self.full = "Cat"
                self.namespace = ""
                self.namespaceKey = 0
                self.text = "Cat"
            default:
                self.full = "Talk: Dog"
                self.namespace = "Talk"
                self.namespaceKey = 1
                self.text = "Dog"
            }
        }
    }
}

fileprivate extension RemoteNotificationsAPIController.NotificationsResult.Notification.Agent {
    init(testing: Bool, randomCategoryAndType: (String, String), project: RemoteNotificationsProject) {
        
        switch project {
        case .commons:
            switch randomCategoryAndType {
            case (("edit-user-talk", "edit-user-talk")):
                self.id = String(302461)
                self.name = "Wikimedia Commons Welcome"
                return
            default:
                break
            }
        default:
            break
        }
        
        let random = Int.random(in: 1...2)
        if random == 1 {
            self.id = String(0)
            self.name = "47.184.10.84"
            return
        }
        
        self.id = String(42540)
        self.name = "TSevener (WMF)"
    }
}

fileprivate extension RemoteNotificationsAPIController.NotificationsResult.Notification.Message {
    init(testing: Bool, identifier: String) {
        self.header = "\(identifier)"
        self.body = "Test body text for identifier: \(identifier)"
        let primaryLink = RemoteNotificationLink(type: nil, url: URL(string:"https://en.wikipedia.org/wiki/Cat")!, label: "Label for primary link")
        self.links = RemoteNotificationLinks(primary: primaryLink, secondary: nil, legacyPrimary: primaryLink)
    }
}
