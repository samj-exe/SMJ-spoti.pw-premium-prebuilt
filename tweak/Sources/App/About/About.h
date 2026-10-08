// About: the latest Taurus release on GitHub, checked silently and cached for six hours.
#import <UIKit/UIKit.h>
#import "Settings/SGModPage.h"

extern NSString *const SGUpdateCheckedNotification;   // on the main thread, after a check ends either way

// The latest stable GitHub release.
@interface SGUpdateRelease : NSObject
@property (nonatomic, copy) NSString *version;   // without the tag's v
@property (nonatomic, copy) NSString *url;       // the release page, where the .deb is
@end

SGUpdateRelease *SGUpdateNewestRelease(void);
NSString *SGUpdateVersion(void);  // nil unless GitHub has a release newer than this build
void SGCheckForUpdate(void);
UIViewController *SGLicensesPage(void); // Licenses.m: the mod's license and the third-party ones it ships

// Whether the now playing card on the lock screen can open this build. It depends on the signature,
// not on the mod: iOS launches by the App ID of the application-identifier entitlement, so a build
// whose bundle id is not that App ID cannot be opened from the card. Signing.m says so once.
extern NSString *const SGSigningHelpURL;
NSString *SGSigningAppIdentifier(void);      // App ID without the team prefix, nil if unreadable
BOOL SGSigningOpensFromLockScreen(void);     // YES when unreadable, so a build that works stays quiet
SGModRow *SGSigningWarningRow(void);          // nil while the signature is sound
void SGCheckSigningOnce(void);
void SGShowSigningFixIfPending(void);   // the sheet the tour held back, if any

// Backup.m: the settings out to a JSON file through the share sheet, and back in from one, replacing
// what is set and restarting.
void SGExportSettings(void);
void SGImportSettings(void);

// AppIcon.m: the row that opens the list of app icons, nil in a build without them (scripts/app-icons.sh).
SGModRow *SGAppIconRow(void);

UIViewController *SGAboutPage(void);   // the Mod page
