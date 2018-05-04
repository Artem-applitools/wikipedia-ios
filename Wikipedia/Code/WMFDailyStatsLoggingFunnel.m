#import "WMFDailyStatsLoggingFunnel.h"
#import "Wikipedia-Swift.h"
#import <WMF/NSCalendar+WMFCommonCalendars.h>

static NSString *const kAppInstallAgeKey = @"appInstallAgeDays";
static NSString *const kAppInstallIdKey = @"appInstallID";

@implementation WMFDailyStatsLoggingFunnel

- (instancetype)init {
    // https://meta.wikimedia.org/wiki/Schema:MobileWikiAppDailyStats
    self = [super initWithSchema:@"MobileWikiAppDailyStats" version:12637385];
    if (self) {
        self.appInstallId = [self persistentUUID:@"WMFDailyStatsLoggingFunnel"];
    }
    return self;
}

- (void)logAppNumberOfDaysSinceInstall {
    NSUserDefaults *userDefaults = [NSUserDefaults wmf_userDefaults];

    NSDate *installDate = [userDefaults wmf_appInstallDate];
    NSParameterAssert(installDate);
    if (!installDate) {
        return;
    }

    NSDate *currentDate = [NSDate date];
    NSInteger daysInstalled = [[NSCalendar wmf_gregorianCalendar] wmf_daysFromDate:installDate toDate:currentDate];

    NSNumber *daysInstalledNumber = [userDefaults wmf_loggedDaysInstalled];

    if (daysInstalledNumber != nil) {
        NSInteger lastLoggedDaysInstalled = [daysInstalledNumber integerValue];
        if (lastLoggedDaysInstalled == daysInstalled) {
            return;
        }
    }

    [self log:@{ kAppInstallAgeKey: @(daysInstalled) }];
}

- (void)logged:(NSDictionary *)eventData {
    NSInteger daysInstalled = (NSInteger)eventData[kAppInstallAgeKey];
    [[NSUserDefaults wmf_userDefaults] wmf_setLoggedDaysInstalled:@(daysInstalled)];
}

- (NSDictionary *)preprocessData:(NSDictionary *)eventData {
    if (!eventData) {
        return nil;
    }
    NSMutableDictionary *dict = [eventData mutableCopy];
    dict[kAppInstallIdKey] = self.appInstallId;
    return [dict copy];
}

@end
