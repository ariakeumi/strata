#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL STReadViewIsFlipped(NSView *view);
FOUNDATION_EXPORT BOOL STReadViewIsOpaque(NSView *view);
FOUNDATION_EXPORT NSRect STConvertViewRect(NSView *view, NSRect rect);
FOUNDATION_EXPORT BOOL STViewProbeIsMainThread(void);

NS_ASSUME_NONNULL_END
