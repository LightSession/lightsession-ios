#import <Foundation/Foundation.h>

#if __has_include(<QuartzCore/QuartzCore.h>)
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// The presented state of a layer, or `nil` if asking for it raised.
///
/// This file exists for one reason, and it is not a style preference: **Swift cannot catch an Objective-C
/// exception.** `-[CALayer presentation]` can raise one — `-[NSConcreteValue doubleValue]: unrecognized selector`
/// — when a layer is animating a property boxed in an `NSValue` the interpolator does not expect. It is rare and
/// it is a crash in the host app, which is not a trade a recorder gets to make.
///
/// It is a known enough hazard that the guard is not optional. Without the wrapper the only safe option is to not
/// read presented geometry at all — and presented geometry is the difference between a replay that shows a
/// transition correctly and one that shows masks beside the words they should cover.
///
/// Returns the presentation layer when there is one, `nil` when the layer is not animating, and `nil` when the
/// call raised. The caller cannot tell the last two apart, and must not need to: both mean "fall back to the
/// model layer", which is correct when nothing is animating and merely imprecise when something is.
CALayer *_Nullable LightSessionPresentationLayer(CALayer *layer);

NS_ASSUME_NONNULL_END

#endif
