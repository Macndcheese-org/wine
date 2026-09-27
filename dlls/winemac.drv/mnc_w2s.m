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
    NSView* wineView;
    NSView* hit;

    if (![window isKindOfClass:[WineWindow class]]) return NO;
    /* Wine's own view: with a window sidebar that's the split view's detail
       pane, not the window's whole content view. */
    wineView = [(WineWindow*)window wineContentView];
    if (!wineView || ![wineView superview]) return NO;
    /* Outside wine's view (the window sidebar, the toolbar): native, it never
       reaches wine. */
    hit = [wineView hitTest:[[wineView superview] convertPoint:[event locationInWindow] fromView:nil]];
    if (!hit) return YES;
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
    NSView* view;
    NSWindow* window;
    NSView* wineView;
    NSView* ancestor;

    if (![responder isKindOfClass:[NSView class]])
        return NO;
    if (key != kVK_Tab && key != kVK_Escape && key != kVK_Return && key != kVK_ANSI_KeypadEnter)
        return NO;
    if ((key == kVK_Return || key == kVK_ANSI_KeypadEnter) &&
        [responder isKindOfClass:[NSTextView class]] && ![(NSTextView*)responder isFieldEditor])
        return NO;
    view = (NSView*)responder;
    if (macdrv_w2s_host_for_view(view))
        return YES;
    /* The window sidebar's list and friends: Tab/Escape/Return drive the
       Win32 dialog even when the first responder is outside wine's view. */
    window = [view window];
    if (![window isKindOfClass:[WineWindow class]])
        return NO;
    wineView = [(WineWindow*)window wineContentView];
    for (ancestor = view; ancestor; ancestor = [ancestor superview])
        if (ancestor == wineView)
            return NO;
    return YES;
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
        NSView* content = [window wineContentView];
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


/***********************************************************************
 *              A real window sidebar (MNC Win32-to-SwiftUI)
 *
 * A property sheet with more than 5 pages gets a native sidebar: the
 * window gets an NSSplitViewController whose sidebar item is a native
 * sidebar (full window height, system material), with the system toggle
 * in a unified toolbar, like a NavigationSplitView app. Wine's own content
 * (the pages and OK/Cancel/Apply) lives in the split view's detail pane;
 * the window is wider than wine's content by w2sLeading and taller by
 * w2sTop. Collapsing the sidebar grows/shrinks the window by its width, so
 * wine's content (fixed-size Win32 pages) never changes.
 */

/* cocoa_window.m's own (class extension) */
@interface WineWindow (W2SPrivate)
- (void) setFrameAndWineFrame:(NSRect)frame;
@end

/* The titlebar and toolbar over a full-size content view: what the content
   layout rect leaves out at the top. A unified toolbar's usual height when
   the window can't tell yet. */
static CGFloat w2s_toolbar_height(NSWindow* window)
{
    CGFloat top = NSHeight([window frame]) - NSMaxY([window contentLayoutRect]);
    return (top > 0 && top < 200) ? top : 52;
}

@interface WineWindow (W2SSidebar)
- (void) w2sAttachSidebar:(NSViewController*)sidebar width:(CGFloat)width;
- (void) w2sAttachSidebar:(NSViewController*)sidebar widthNumber:(NSNumber*)width;
- (void) w2sDetachSidebar;
- (void) w2sSidebarCollapsedChanged;
- (BOOL) w2sSidebarCollapsed;
- (void) w2sSetSidebarCollapsed:(NSNumber*)collapsed;
@end


/* The split view's toolbar delegate: the system toggle and its separator
   only, and the observer that keeps the window around the sidebar. The
   window owns it (the toolbar's delegate is weak); it doesn't retain the
   window back, which would keep both alive forever. */
@interface W2SSidebarToolbarDelegate : NSObject<NSToolbarDelegate>
{
    WineWindow* window;     /* not retained: the window owns us */
}
- (instancetype) initWithWindow:(WineWindow*)win;
@end


@implementation W2SSidebarToolbarDelegate

- (instancetype) initWithWindow:(WineWindow*)win
{
    self = [super init];
    if (self)
        window = win;
    return self;
}

- (NSArray*) toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar
{
    return [NSArray arrayWithObjects:NSToolbarToggleSidebarItemIdentifier,
                     NSToolbarSidebarTrackingSeparatorItemIdentifier, nil];
}

- (NSArray*) toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSToolbarItem*) toolbar:(NSToolbar*)toolbar itemForItemIdentifier:(NSString*)itemIdentifier
    willBeInsertedIntoToolbar:(BOOL)flag
{
    return nil;  /* the toggle and the separator are system items */
}

- (void) observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object
                         change:(NSDictionary*)change context:(void*)context
{
    if ([keyPath isEqualToString:@"collapsed"])
        [window w2sSidebarCollapsedChanged];
    else
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

@end


@implementation WineWindow (W2SSidebar)

- (void) w2sAttachSidebar:(NSViewController*)sidebar width:(CGFloat)width
{
    NSRect content;
    NSView* wineView;
    NSSplitViewController* split;
    NSSplitViewItem* side;
    NSViewController* detailVC;
    NSToolbar* toolbar;
    W2SSidebarToolbarDelegate* delegate;
    NSResponder* firstResponder;

    /* Main thread; attach once. */
    if (w2sSplit || !sidebar || width <= 0) return;

    content = [self contentRectForFrameRect:[self frame]];  /* wine's content, before */
    firstResponder = [self firstResponder];
    wineView = [[self contentView] retain];

    split = [[NSSplitViewController alloc] init];
    side = [NSSplitViewItem sidebarWithViewController:sidebar];
    side.minimumThickness = side.maximumThickness = width;
    side.canCollapse = YES;
    side.allowsFullHeightLayout = YES;   /* macOS 11+ */
    detailVC = [[NSViewController alloc] init];
    detailVC.view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, content.size.width, content.size.height)] autorelease];
    [split addSplitViewItem:side];
    [split addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:detailVC]];

    delegate = [[W2SSidebarToolbarDelegate alloc] initWithWindow:self];
    toolbar = [[[NSToolbar alloc] initWithIdentifier:@"org.winehq.w2s.sidebar"] autorelease];
    [toolbar setDisplayMode:NSToolbarDisplayModeIconOnly];
    [toolbar setDelegate:delegate];

    [self setStyleMask:[self styleMask] | NSWindowStyleMaskFullSizeContentView];
    [self setToolbar:toolbar];
    [self setToolbarStyle:NSWindowToolbarStyleUnified];

    w2sWineView = wineView;
    w2sSplit = [split retain];
    w2sSidebarItem = side;
    w2sToolbarDelegate = [delegate retain];
    [split release];
    [delegate release];

    self.contentViewController = split;

    /* Size the window around wine's content, then measure the titlebar and
       toolbar at that size: assigning the content view controller resized
       the window to the split view's own idea of its size, so measuring
       before this gives nonsense. */
    w2sSidebarWidth = w2sLeading = width;
    w2sTop = 0;
    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];
    [self.contentView layoutSubtreeIfNeeded];
    w2sTop = w2s_toolbar_height(self);
    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];  /* wine's content doesn't move */

    [self.contentView layoutSubtreeIfNeeded];
    wineView.frame = NSMakeRect(0, 0, NSWidth(detailVC.view.bounds), NSHeight(detailVC.view.bounds) - w2sTop);
    wineView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [detailVC.view addSubview:wineView];
    [wineView release];
    [detailVC release];

    [side addObserver:w2sToolbarDelegate forKeyPath:@"collapsed" options:0 context:NULL];

    if (firstResponder == wineView && [wineView acceptsFirstResponder])
        [self makeFirstResponder:wineView];
}

- (void) w2sAttachSidebar:(NSViewController*)sidebar widthNumber:(NSNumber*)width
{
    /* performSelector:with:with: can't pass a CGFloat, so the runtime calls this. */
    [self w2sAttachSidebar:sidebar width:[width doubleValue]];
}

- (void) w2sDetachSidebar
{
    NSView* wineView;
    NSRect content;

    /* Main thread. */
    if (!w2sSplit) return;

    content = [self contentRectForFrameRect:[self frame]];  /* wine's content, with the sidebar */
    [w2sSidebarItem removeObserver:w2sToolbarDelegate forKeyPath:@"collapsed"];

    wineView = [w2sWineView retain];
    [wineView removeFromSuperview];
    [wineView setFrame:NSMakeRect(0, 0, content.size.width, content.size.height)];

    self.contentViewController = nil;
    [self setContentView:wineView];
    [self setToolbar:nil];
    [self setStyleMask:[self styleMask] & ~NSWindowStyleMaskFullSizeContentView];
    [wineView release];

    [w2sSplit release];
    w2sSplit = nil;
    w2sSidebarItem = nil;
    [w2sToolbarDelegate release];
    w2sToolbarDelegate = nil;
    w2sWineView = nil;
    w2sLeading = w2sSidebarWidth = w2sTop = 0;

    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];
    if ([wineView acceptsFirstResponder])
        [self makeFirstResponder:wineView];
}

- (void) w2sSidebarCollapsedChanged
{
    NSRect content;

    if (!w2sSplit) return;
    content = [self contentRectForFrameRect:[self frame]];  /* with the OLD w2sLeading */
    w2sLeading = [w2sSidebarItem isCollapsed] ? 0 : w2sSidebarWidth;
    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];
}

- (BOOL) w2sSidebarCollapsed
{
    return w2sSidebarItem ? [w2sSidebarItem isCollapsed] : NO;
}

- (void) w2sSetSidebarCollapsed:(NSNumber*)collapsed
{
    if (w2sSplit)
        [w2sSidebarItem setCollapsed:[collapsed boolValue]];
}

@end
