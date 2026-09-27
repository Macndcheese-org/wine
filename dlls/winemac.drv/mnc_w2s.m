/*
 * MNC Win32-to-SwiftUI: host views for native controls.
 *
 * win32swiftui.dll translates Win32 controls into SwiftUI. For each translated
 * control, winemac keeps one WineW2SHostView over the control's client area,
 * as a subview of the top-level window's content view; win32swiftui.so puts an
 * NSHostingView inside it. Geometry and visibility follow the control through
 * the client-surface machinery (window.c).
 *
 * Clicks that land on a hosted SwiftUI view stay native: the app-level mouse
 * handler doesn't forward them to wine (macdrv_w2s_event_in_host). Native
 * events travel back through the thread's event queue as W2S_WAKE, which
 * event.c turns into a posted message to the control.
 */

#include "config.h"

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

#include "macdrv_cocoa.h"
#import "cocoa_app.h"
#import "cocoa_event.h"
#import "cocoa_window.h"


@implementation WineW2SHostView

@synthesize hwnd, message;

    - (instancetype) initWithQueue:(WineEventQueue*)inQueue hwnd:(uint64_t)inHwnd message:(unsigned int)inMessage
    {
        self = [super initWithFrame:NSZeroRect];
        if (self)
        {
            queue = [inQueue retain];
            hwnd = inHwnd;
            message = inMessage;
            [self setAutoresizingMask:NSViewNotSizable];
            [self setHidden:YES];
        }
        return self;
    }

    - (void) dealloc
    {
        [queue release];
        [super dealloc];
    }

    - (WineEventQueue*) queue
    {
        return queue;
    }

    - (BOOL) isFlipped
    {
        return YES;
    }

    - (BOOL) acceptsFirstMouse:(NSEvent*)event
    {
        return YES;
    }

    /* Transparent where nothing native is drawn, so those clicks reach wine. */
    - (NSView*) hitTest:(NSPoint)point
    {
        NSView* hit = [super hitTest:point];
        return hit == self ? nil : hit;
    }

@end


/***********************************************************************
 *              macdrv_w2s_host_for_view
 *
 * The host view that contains view, or nil.
 */
WineW2SHostView *macdrv_w2s_host_for_view(NSView *view)
{
    for (; view; view = [view superview])
        if ([view isKindOfClass:[WineW2SHostView class]])
            return (WineW2SHostView*)view;
    return nil;
}


/***********************************************************************
 *              macdrv_w2s_event_in_host
 *
 * Whether a mouse event hits a native control inside a host view. Such
 * events are handled by AppKit and must not also reach wine.
 */
BOOL macdrv_w2s_event_in_host(NSEvent *event)
{
    NSWindow* window = [event window];
    NSView* content = [window contentView];
    NSView* hit;

    if (!content || ![[content subviews] count]) return NO;
    hit = [content hitTest:[[content superview] convertPoint:[event locationInWindow] fromView:nil]];
    return macdrv_w2s_host_for_view(hit) != nil;
}


/***********************************************************************
 *              macdrv_w2s_key_goes_to_wine
 *
 * Keys that drive Win32 dialog navigation (Tab, Escape, Return outside
 * multi-line text) go to wine even when a native control has keyboard focus,
 * so IsDialogMessage keeps moving focus and pressing default buttons.
 */
BOOL macdrv_w2s_key_goes_to_wine(NSEvent *event, NSResponder *responder)
{
    unsigned short key = [event keyCode];

    if (![responder isKindOfClass:[NSView class]] || !macdrv_w2s_host_for_view((NSView*)responder))
        return NO;
    if (key == kVK_Tab || key == kVK_Escape)
        return YES;
    if (key == kVK_Return || key == kVK_ANSI_KeypadEnter)
        return !([responder isKindOfClass:[NSTextView class]] && ![(NSTextView*)responder isFieldEditor]);
    return NO;
}


/***********************************************************************
 *              macdrv_w2s_create_host
 */
WineW2SHostView *macdrv_w2s_create_host(WineEventQueue *queue, uint64_t hwnd, unsigned int message)
{
@autoreleasepool
{
    __block WineW2SHostView* view;

    OnMainThread(^{
        view = [[WineW2SHostView alloc] initWithQueue:queue hwnd:hwnd message:message];
    });
    return view;
}
}


/***********************************************************************
 *              macdrv_w2s_dispose_host
 */
void macdrv_w2s_dispose_host(WineW2SHostView *view)
{
@autoreleasepool
{
    OnMainThreadAsync(^{
        [view removeFromSuperview];
        [view release];
    });
}
}


/***********************************************************************
 *              macdrv_w2s_set_host_geometry
 *
 * Puts the host over the control: rect is in the top-level window's
 * coordinates (client_surface monitor_rect), like client-surface views.
 */
void macdrv_w2s_set_host_geometry(WineW2SHostView *view, WineWindow *window, CGRect rect, bool hidden)
{
@autoreleasepool
{
    if (CGRectIsNull(rect)) rect = CGRectZero;

    OnMainThreadAsync(^{
        NSView* content = [window contentView];
        NSRect frame = NSRectFromCGRect(cgrect_mac_from_win(rect));

        if (content && [view superview] != content)
        {
            [view removeFromSuperview];
            [content addSubview:view positioned:NSWindowAbove relativeTo:nil];
        }
        if (!NSEqualRects([view frame], frame))
            [view setFrame:frame];
        [view setHidden:hidden || !content || NSIsEmptyRect(frame)];
    });
}
}


/***********************************************************************
 *              macdrv_w2s_post_wake
 *
 * Thread-safe; called by win32swiftui.so (usually on the main thread) when
 * the native control has events for the Win32 side. The control's thread
 * receives W2S_WAKE and posts the host's message to the control.
 */
void macdrv_w2s_post_wake(WineW2SHostView *view, uint64_t cookie)
{
    macdrv_event* event = macdrv_create_event(W2S_WAKE, nil);

    event->w2s_wake.hwnd = view.hwnd;
    event->w2s_wake.message = view.message;
    event->w2s_wake.cookie = cookie;
    [[view queue] postEvent:event];
    macdrv_release_event(event);
}
