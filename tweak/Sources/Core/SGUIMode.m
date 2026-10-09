#import "SGUIMode.h"
#import "SGLog.h"
#import "SGPrefs.h"

BOOL SGRedesignAvailable(void) {
    return @available(iOS 17.0, *);
}

BOOL SGRedesignedUI(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        on = SGRedesignedUIStored();
        if (@available(iOS 26.0, *)) {
            SGLog(@"ui: %@ (Liquid Glass)", on ? @"redesigned" : @"native");
        } else if (@available(iOS 17.0, *)) {
            SGLog(@"ui: %@ (iOS 18 blur)", on ? @"redesigned" : @"native");
        } else {
            SGLog(@"ui: %@", on ? @"redesigned" : @"native");
        }
    });
    return on;
}

BOOL SGNativeUI(void) {
    return !SGRedesignedUI();
}

BOOL SGRedesignedUIStored(void) {
    // Leave the stored preference in place so a phone that upgrades to iOS 26 keeps the redesign mode it
    // was last asked for. On iOS 17–25 the same switch still enables the iOS 18-style blur redesign.
    return SGRedesignAvailable() && SGFlag(SGKeyRedesign, NO);
}
