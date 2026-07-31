#import "include/LightSessionSafe.h"

#if __has_include(<QuartzCore/QuartzCore.h>)

CALayer *_Nullable LightSessionPresentationLayer(CALayer *layer) {
    @try {
        // `presentationLayer` in Objective-C; Swift renames it to `presentation()`.
        return [layer presentationLayer];
    } @catch (NSException *exception) {
        // Swallowed on purpose, and not logged: this runs once per view per captured frame, so a log here would
        // be thousands of identical lines a second on the one device where it happens. The caller falls back to
        // the model layer, which is the same thing it did before this file existed.
        return nil;
    }
}

#endif
