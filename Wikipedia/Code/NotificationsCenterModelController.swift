
import Foundation
import WMF

protocol NotificationsCenterModelControllerDelegate: AnyObject {
    func reloadCellWithViewModelIfNeeded(viewModel: NotificationsCenterCellViewModel)
}

//Keeps track of the RemoteNotification managed objects and NotificationCenterCellViewModels that power Notification Center in a performant way
final class NotificationsCenterModelController {
    
    typealias RemoteNotificationKey = String

    private var cellViewModelsDict: [RemoteNotificationKey: NotificationsCenterCellViewModel] = [:]
    private var cellViewModels: Set<NotificationsCenterCellViewModel> = []
    
    weak var delegate: NotificationsCenterModelControllerDelegate?
    private let languageLinkController: MWKLanguageLinkController
    
    init(languageLinkController: MWKLanguageLinkController, delegate: NotificationsCenterModelControllerDelegate?) {
        self.delegate = delegate
        self.languageLinkController = languageLinkController
    }
    
    func reset() {
        cellViewModelsDict.removeAll()
        cellViewModels.removeAll()
    }
    
    func addNewCellViewModelsWith(notifications: [RemoteNotification]) {

        print("currentViewModels: \(self.cellViewModels)")
        for notification in notifications {

            //Instantiate new view model and insert it into tracking properties
            
            guard let key = notification.key,
                  let newCellViewModel = NotificationsCenterCellViewModel(notification: notification, languageLinkController: languageLinkController) else {
                continue
            }
            
            cellViewModelsDict[key] = newCellViewModel
            print("newViewModel: \(newCellViewModel)")
            cellViewModels.insert(newCellViewModel)
            print("currentViewModels: \(self.cellViewModels)")
        }
    }
    
    func updateCurrentCellViewModelsWith(updatedNotifications: [RemoteNotification]? = nil) {

        let cellViewModelsToUpdate: [NotificationsCenterCellViewModel]
        
        if let updatedNotifications = updatedNotifications {
            
            //Find existing cell view models via tracking properties
            cellViewModelsToUpdate = updatedNotifications.compactMap { notification in
                
                guard let key = notification.key else {
                    return nil
                }
                
                return cellViewModelsDict[key]
                
            }
            
        } else {
            cellViewModelsToUpdate = Array(cellViewModels)
        }
        
        cellViewModelsToUpdate.forEach {
            self.delegate?.reloadCellWithViewModelIfNeeded(viewModel: $0)
        }
    }
    
    var fetchOffset: Int {
        if cellViewModels.count > 3 {
            return cellViewModels.count - 3
        }
        
        return cellViewModels.count
    }
    
    var sortedCellViewModels: [NotificationsCenterCellViewModel] {
        return cellViewModels.sorted { lhs, rhs in
            guard let lhsDate = lhs.notification.date,
                  let rhsDate = rhs.notification.date else {
                return false
            }
            return lhsDate > rhsDate
        }
    }
}
