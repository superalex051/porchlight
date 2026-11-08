// Declarations of private Apple symbols, weak-imported and wrapped by ADSPI.
// Classes and methods below were checked by runtime introspection on macOS 27.0.1, which can't
// see a block's arguments. They are minimal: only what ADSPI calls. All are exported by CoreGraphics.
#ifndef CPRIVATESPI_H
#define CPRIVATESPI_H

#include <CoreGraphics/CoreGraphics.h>

extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef _Nonnull config, CGDirectDisplayID display, bool enabled)
    __attribute__((weak_import));

// Hidden from plain C: empty.c compiles as C, and this target's module can be built that way.
#ifdef __OBJC__

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// `init` is left out on purpose. Declared here, Swift would import it as failable, and
// NSObject's inherited one is what these classes use.

__attribute__((weak_import))
@interface CGVirtualDisplayMode : NSObject
- (nullable instancetype)initWithWidth:(unsigned int)width
                                height:(unsigned int)height
                           refreshRate:(double)refreshRate;
@end

__attribute__((weak_import))
@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
@end

__attribute__((weak_import))
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
// Apple calls this block with one argument, not two. -[VirtualDisplayClient proxyGone] in
// CoreDisplay passes only the context it stored, and -[CGVirtualDisplay initWithDescriptor:] sets
// that context to itself, unretained. A second declared argument would read an unset register, and
// an object type would make the Swift thunk retain the pointer, so it is a raw pointer nothing uses.
// Determined from the CoreGraphics and CoreDisplay disassembly on macOS 27.0.1, and by stand-in
// classes: the two-argument shape crashed in objc_retain, the one-argument shape exited cleanly.
@property(nullable, copy, nonatomic) void (^terminationHandler)(void *_Nullable);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

__attribute__((weak_import))
@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END

#endif // __OBJC__

#endif // CPRIVATESPI_H
