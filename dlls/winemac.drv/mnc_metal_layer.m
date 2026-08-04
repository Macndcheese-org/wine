/*
 * MNC HACK 14: implementation of MNCMetalLayer.
 *
 * The Cocoa wineserver event handler picks the event up off the
 * window's queue and turns the embedded client_surface pointer into a
 * win32u client_surface_present() call, which marks the per-swapchain
 * view visible. Until that fires, the rendered Metal content sits in
 * a layer that wine never tells the window-server about, so the
 * window stays empty.
 *
 * We attach the client_surface pointer to each WineContentView using
 * Apple's objc associated-object machinery — chosen over a separate
 * dictionary so the lifetime is naturally tied to the view, and over
 * extending the view's @public ivars so we don't have to edit
 * cocoa_window.m's primary @interface block.
 */

#if defined(__x86_64__)

#include "config.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include "macdrv_cocoa.h"
#import "cocoa_app.h"
#import "cocoa_event.h"
#import "cocoa_window.h"
#import "dxmt_objc.h"
#import "mnc_metal_layer.h"

/* Key for objc_set/getAssociatedObject — only the pointer identity is
 * used, the value isn't dereferenced. */
static char mnc_view_client_surface_key;

/* C-callable accessors exported via macdrv_cocoa.h so the unixlib
 * bridge in d3dmetal_bridge.c can talk to us. */
void *macdrv_get_view_d3dmetal_client_surface(macdrv_view v)
{
@autoreleasepool
{
    if (!v) return NULL;
    return (__bridge void *)objc_getAssociatedObject((__bridge id)v, &mnc_view_client_surface_key);
}
}

void macdrv_set_view_d3dmetal_client_surface(macdrv_view v, void *client_surface)
{
@autoreleasepool
{
    if (!v) return;
    /* OBJC_ASSOCIATION_ASSIGN — the wineserver owns the lifetime, we
     * don't retain/copy from the objc side. */
    objc_setAssociatedObject((__bridge id)v,
                             &mnc_view_client_surface_key,
                             (__bridge id)client_surface,
                             OBJC_ASSOCIATION_ASSIGN);
}
}


@implementation MNCMetalLayer

    /* Override -nextDrawable to emit a present-notification event
     * back into wine before forwarding to the real CAMetalLayer
     * implementation. The CAMetalLayer/CALayer delegate of a
     * layer-backed NSView is always that NSView, so self.delegate is
     * the WineMetalView holding us — its parent is the
     * WineContentView whose client_surface we stored at view-creation
     * time.
     *
     * [super nextDrawable] is WineMetalLayer's, which runs the same
     * check against the DXMT client_surface tag before reaching the real
     * CAMetalLayer implementation. */
    - (id<CAMetalDrawable>) nextDrawable
    {
        Class metalViewClass    = NSClassFromString(@"WineMetalView");
        Class contentViewClass  = NSClassFromString(@"WineContentView");
        Class windowClass       = NSClassFromString(@"WineWindow");

        if (metalViewClass && [self.delegate isKindOfClass:metalViewClass])
        {
            NSView *mv     = (NSView *)self.delegate;
            NSView *cv     = mv.superview;
            NSWindow *win  = mv.window;
            if (cv  && [cv  isKindOfClass:contentViewClass] &&
                win && [win isKindOfClass:windowClass])
            {
                void *client_surface =
                    macdrv_get_view_d3dmetal_client_surface((macdrv_view)cv);
                if (client_surface)
                {
                    macdrv_event *ev =
                        macdrv_create_event(CLIENT_SURFACE_PRESENTED,
                                            (WineWindow *)win);
                    if (ev)
                    {
                        ev->client_surface_presented.client_surface = client_surface;
                        WineEventQueue *q = [(WineWindow *)win queue];
                        [q postEvent:ev];
                        macdrv_release_event(ev);
                    }
                }
            }
        }

        return [super nextDrawable];
    }

@end

#endif /* __x86_64__ */
