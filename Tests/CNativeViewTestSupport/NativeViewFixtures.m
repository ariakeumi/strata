#import "NativeViewFixtures.h"

BOOL STReadViewIsFlipped(NSView *view) { return view.isFlipped; }
BOOL STReadViewIsOpaque(NSView *view) { return view.isOpaque; }
NSRect STConvertViewRect(NSView *view, NSRect rect) { return [view convertRect:rect toView:nil]; }
BOOL STViewProbeIsMainThread(void) { return NSThread.isMainThread; }
