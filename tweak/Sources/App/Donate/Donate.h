// Optional, user-initiated Ko-fi support from the Mod Settings page.
#import <UIKit/UIKit.h>
#import "Settings/SGModPage.h"

extern NSString *const SGKofiURL;
UIColor *SGKofiColor(void);

// A glass capsule with a Ko-fi rim circling it and a breathing glow. Prominent tints the glass itself.
@interface SGKofiButton : UIControl
- (instancetype)initWithTitle:(NSString *)title prominent:(BOOL)prominent;
@end

void SGShowDonateSheet(void);
SGModRow *SGDonateRow(void);
