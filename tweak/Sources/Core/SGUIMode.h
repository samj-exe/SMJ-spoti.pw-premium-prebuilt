// Which of the two looks runs: Spotify's own screens with the mod's tweaks on them (Native/), or the
// redesign (Redesigned/), picked by Redesigned UI in Appearance. What does not draw on Spotify's
// screens (Shared/) runs under both. The switch is read once, the first time anything asks, so the
// hooks, the flags and the pages see one answer for the whole launch and a change waits for the restart.
//
// Every hook file of Native/ starts its %ctor with `if (!SGNativeUI()) return;`, every one of
// Redesigned/ with `if (!SGRedesignedUI()) return;`: the two never run together, which is what lets
// each hook the same Spotify class in its own way.
// Threading: safe from any thread.
#import <Foundation/Foundation.h>

#define SGKeyRedesign @"spotifyglass.redesign"

// The redesign is available from iOS 17 onward. On iOS 26+ it uses the system Liquid Glass material,
// and on iOS 17–25 it falls back to the iOS 18-style blur look, so the UI choice works across the range.
BOOL SGRedesignAvailable(void);

BOOL SGRedesignedUI(void);
BOOL SGNativeUI(void);
// The stored switch rather than the launch's, for settings pages opened after it was flipped: they
// show what the restart will bring.
BOOL SGRedesignedUIStored(void);
