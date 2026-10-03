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

    /* The control's rectangle, reaching its outsets beyond it (the view is
       flipped, as wine's content view is). */
    - (void) w2sApplyFrame:(NSRect)frame
    {
        wineFrame = frame;
        frame.origin.x -= outsetLeft;
        frame.origin.y -= outsetTop;
        frame.size.width = MAX(0, frame.size.width + outsetLeft + outsetRight);
        frame.size.height = MAX(0, frame.size.height + outsetTop + outsetBottom);
        if (!NSEqualRects([self frame], frame))
            [self setFrame:frame];
    }

    - (void) w2sSetOutsetTop:(NSNumber*)top
    {
        outsetTop = MAX(0, [top doubleValue]);
        [self w2sApplyFrame:wineFrame];
    }

    - (void) w2sSetOutsets:(NSArray*)outsets
    {
        if ([outsets count] < 4) return;
        outsetTop = MAX(0, [[outsets objectAtIndex:0] doubleValue]);
        outsetLeft = MAX(0, [[outsets objectAtIndex:1] doubleValue]);
        /* below and to the right it may be negative: a form smaller than the control it covers */
        outsetBottom = [[outsets objectAtIndex:2] doubleValue];
        outsetRight = [[outsets objectAtIndex:3] doubleValue];
        [self w2sApplyFrame:wineFrame];
    }

    - (BOOL) w2sFront
    {
        return front;
    }

    - (void) w2sSetFront:(NSNumber*)flag
    {
        NSView* superview = [self superview];

        front = [flag boolValue];
        if (front && superview)
        {
            [self retain];
            [self removeFromSuperview];
            [superview addSubview:self positioned:NSWindowAbove relativeTo:nil];
            [self release];
        }
    }

    - (BOOL) w2sBehind
    {
        return behind;
    }

    - (void) w2sSetBehind:(NSNumber*)flag
    {
        NSView* superview = [self superview];

        behind = [flag boolValue];
        if (behind && superview)
        {
            [self retain];
            [self removeFromSuperview];
            [superview addSubview:self positioned:NSWindowBelow relativeTo:nil];
            [self release];
        }
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
    NSView* content;
    NSView* wineView;
    NSView* hit;

    if (![window isKindOfClass:[WineWindow class]]) return NO;
    /* Wine's own view: with a native toolbar or sidebar that's inside the
       window's content view, not all of it. */
    wineView = [(WineWindow*)window wineContentView];
    content = [window contentView];
    if (!wineView || ![wineView superview] || !content) return NO;
    /* What the click lands on: anything but wine's view (the sidebar floating
       over it, the toolbar, the margins beside wine's content) is native, and
       the click never reaches wine. */
    hit = [content hitTest:[[content superview] convertPoint:[event locationInWindow] fromView:nil]];
    if (!hit || (hit != wineView && ![hit isDescendantOf:wineView])) return YES;
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
    /* A native toolbar and friends: Tab/Escape/Return drive the Win32
       dialog even when the first responder is outside wine's view. */
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
            [content addSubview:view positioned:([view w2sBehind] ? NSWindowBelow : NSWindowAbove) relativeTo:nil];
            /* a host in front (a settings form over its sheet) stays above the newcomer */
            for (NSView* other in [[[content subviews] copy] autorelease])
                if (other != view && [other isKindOfClass:[WineW2SHostView class]] && [(WineW2SHostView*)other w2sFront])
                    [(WineW2SHostView*)other w2sSetFront:@YES];
        }
        [view w2sApplyFrame:frame];
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
 *              A native toolbar in the window frame (MNC Win32-to-SwiftUI)
 *
 * The runtime puts an NSToolbar in the window's frame, where a Mac app's
 * toolbar is: a settings window's panes (a property sheet with many pages),
 * later an app's own toolbar. The window gets a full-size content view, a
 * plain container, and wine's own view sits in it below the titlebar and
 * toolbar (w2sTop), with margins beside it when the toolbar needs more room
 * than wine's content has (w2sLeading, w2sTrailing). The window grows around
 * wine's content, which neither moves nor changes size.
 */

/* cocoa_window.m's own (class extension) */
@interface WineWindow (W2SPrivate)
- (void) setFrameAndWineFrame:(NSRect)frame;
@end

/* The titlebar and toolbar over a full-size content view: what the content
   layout rect leaves out at the top. A toolbar's usual height when the
   window can't tell yet. */
static CGFloat w2s_toolbar_height(NSWindow* window)
{
    CGFloat top = NSHeight([window frame]) - NSMaxY([window contentLayoutRect]);
    return (top > 0 && top < 200) ? top : 52;
}


/* the program's names, for the titles of its windows (macdrv_w2s_window_title, below) */
static NSMutableSet* mnc_app_names;
static NSMutableSet* mnc_about_texts;
static NSString* mnc_fold(NSString* s);

@implementation WineWindow (W2SChrome)

/* wine's view in the container: below the toolbar, between the margins. It
   sits at the origin of a holder that takes the place: wine positions its own
   layer at its superlayer's origin (updateLayer), whatever the view's frame. */
- (void) w2sLayoutWineView
{
    NSView* holder = [w2sWineView superview];
    NSRect bounds = [w2sContainer bounds];

    [holder setFrame:NSMakeRect(w2sLeading, 0, NSWidth(bounds) - w2sLeading - w2sTrailing,
                                NSHeight(bounds) - w2sTop)];
    [w2sWineView setFrame:[holder bounds]];

    /* The sidebar's content starts below the titlebar (and toolbar). AppKit gives
       it no titlebar inset here: the window's content rect (the frame math above)
       already leaves the titlebar out. */
    if (w2sSplit)
    {
        NSView* side = [[[[w2sSplit splitViewItems] firstObject] viewController] view];
        [side setAdditionalSafeAreaInsets:NSEdgeInsetsMake(w2sTop, 0, 0, 0)];
    }
}

/* The window's content becomes a full-size container, wine's view in a holder
   in it below the titlebar; the window grows around wine's content, which
   neither moves nor changes size. */
- (void) w2sMakeChrome
{
    NSRect content;
    NSView* wineView;
    NSView* container;
    NSView* holder;
    NSResponder* firstResponder;

    if (w2sChrome) return;
    content = [self contentRectForFrameRect:[self frame]];  /* wine's content, before */
    firstResponder = [self firstResponder];
    wineView = [[self contentView] retain];
    container = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(content), NSHeight(content))] autorelease];
    holder = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(content), NSHeight(content))] autorelease];

    [self setStyleMask:[self styleMask] | NSWindowStyleMaskFullSizeContentView];
    [self setContentView:container];

    w2sChrome = YES;
    w2sWineView = wineView;
    w2sContainer = container;
    w2sLeading = w2sTrailing = 0;
    w2sTop = 0;
    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];
    [container layoutSubtreeIfNeeded];
    w2sTop = w2s_toolbar_height(self);
    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];

    [holder setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [wineView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [container addSubview:holder];
    [holder addSubview:wineView];
    [self w2sLayoutWineView];
    [wineView release];

    if (firstResponder == wineView && [wineView acceptsFirstResponder])
        [self makeFirstResponder:wineView];
}

/* no toolbar and no sidebar any more: wine's view is the content view again */
- (void) w2sDropChromeIfUnused
{
    NSView* wineView;
    NSRect content;

    if (!w2sChrome || [self toolbar] || w2sSplit) return;
    content = [self contentRectForFrameRect:[self frame]];  /* wine's content */
    wineView = [w2sWineView retain];
    [wineView removeFromSuperview];
    [wineView setFrame:NSMakeRect(0, 0, NSWidth(content), NSHeight(content))];

    [self setContentView:wineView];
    [self setStyleMask:[self styleMask] & ~NSWindowStyleMaskFullSizeContentView];
    [wineView release];

    w2sChrome = NO;
    w2sWineView = nil;
    w2sContainer = nil;
    w2sLeading = w2sTrailing = w2sTop = 0;

    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];
    if ([wineView acceptsFirstResponder])
        [self makeFirstResponder:wineView];
}

/* the titlebar and toolbar over the content: measured at the window's size */
- (void) w2sRemeasureTop
{
    NSRect content = [self contentRectForFrameRect:[self frame]];  /* wine's content */

    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];
    [w2sContainer layoutSubtreeIfNeeded];
    w2sTop = w2s_toolbar_height(self);
    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];
    [self w2sLayoutWineView];
}

- (void) w2sAttachToolbar:(NSDictionary*)spec
{
    NSToolbar* toolbar = [spec objectForKey:@"toolbar"];
    CGFloat extra = [[spec objectForKey:@"extraWidth"] doubleValue];
    NSRect content;

    /* Main thread; attach once. */
    if ([self toolbar] || ![toolbar isKindOfClass:[NSToolbar class]]) return;

    [self w2sMakeChrome];
    content = [self contentRectForFrameRect:[self frame]];  /* wine's content */
    [self setToolbar:toolbar];
    [self setToolbarStyle:[[spec objectForKey:@"style"] integerValue]];
    w2sLeading = floor(MAX(extra, 0) / 2);
    w2sTrailing = MAX(extra, 0) - w2sLeading;

    /* Size the window around wine's content, then measure the titlebar and
       toolbar at that size, and size again: wine's content doesn't move. */
    w2sTop = 0;
    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];
    [w2sContainer layoutSubtreeIfNeeded];
    w2sTop = w2s_toolbar_height(self);
    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];
    [self w2sLayoutWineView];
}

- (void) w2sDetachToolbar
{
    /* Main thread. */
    if (!w2sChrome || ![self toolbar]) return;
    [self setToolbar:nil];
    w2sLeading = w2sTrailing = 0;
    if (w2sSplit)
        [self w2sRemeasureTop];     /* the titlebar alone over the sidebar's window */
    else
        [self w2sDropChromeIfUnused];
}

/* A native sidebar: the window's content becomes a split view whose sidebar
   item holds the runtime's view (a tree along the window's leading edge, as
   Finder's sidebar) and whose content item is the container. On macOS 26 and
   later the sidebar floats over the content, which stays the window's full
   size underneath: wine's content neither moves nor changes size, and the
   sidebar covers the part the app laid its tree out in. */
- (void) w2sAttachSidebar:(NSDictionary*)spec
{
    NSViewController* side = [spec objectForKey:@"controller"];
    NSViewController* contentController;
    NSSplitViewController* split;
    NSSplitViewItem* sideItem;
    NSSplitViewItem* contentItem;
    NSView* container;
    NSRect frame;

    /* Main thread; attach once. */
    if (w2sSplit || ![side isKindOfClass:[NSViewController class]]) return;
    if (@available(macOS 26.0, *)) {} else return;

    [self w2sMakeChrome];
    frame = [self frame];
    container = [w2sContainer retain];
    [self setContentView:[[[NSView alloc] initWithFrame:[container frame]] autorelease]];
    contentController = [[[NSViewController alloc] init] autorelease];
    [contentController setView:container];
    [container release];

    split = [[NSSplitViewController alloc] init];
    sideItem = [NSSplitViewItem sidebarWithViewController:side];
    /* the toolbar's sidebar button (toggleSidebar:). The sidebar keeps AppKit's
       minimum width: below about 140 pt, hiding it sent the button to the
       toolbar's overflow menu instead of beside the traffic lights. */
    [sideItem setCanCollapse:YES];
    contentItem = [NSSplitViewItem splitViewItemWithViewController:contentController];
    if (@available(macOS 26.0, *))
        [contentItem setAutomaticallyAdjustsSafeAreaInsets:YES];
    [split addSplitViewItem:sideItem];
    [split addSplitViewItem:contentItem];

    w2sSplit = split;
    w2sSidebarTarget = [[spec objectForKey:@"target"] retain];
    /* a content view controller sizes the window to itself: back to wine's size */
    [self setContentViewController:split];
    [self setFrameAndWineFrame:frame];
    [self w2sSetSidebarWidth:[spec objectForKey:@"width"]];
    [self w2sLayoutWineView];

    w2sSidebarObserver = [[[NSNotificationCenter defaultCenter]
        addObserverForName:NSSplitViewDidResizeSubviewsNotification object:[split splitView] queue:nil
                usingBlock:^(NSNotification* note){
        /* collapsed: 0, the app lays itself out without its tree */
        BOOL collapsed = [sideItem isCollapsed];
        CGFloat width = collapsed ? 0 : NSWidth([[side view] frame]);
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSEventType type;
        BOOL user;

        [self w2sLayoutWineView];
        /* the user's: the divider dragged (the event is the mouse's drag; the
           notification names the divider for AppKit's own adjustments too), or the
           sidebar hidden or shown, until its animation ends */
        if (collapsed != w2sSidebarCollapsed)
        {
            w2sSidebarCollapsed = collapsed;
            w2sSidebarToggled = now;
        }
        type = [[NSApp currentEvent] type];
        user = type == NSEventTypeLeftMouseDragged || type == NSEventTypeLeftMouseUp || now - w2sSidebarToggled < 1.0;
        if (user && !w2sSidebarSetting && [w2sSidebarTarget respondsToSelector:@selector(w2sSidebarResized:)])
            [w2sSidebarTarget performSelector:@selector(w2sSidebarResized:) withObject:@(width)];
    }] retain];
}

- (void) w2sDetachSidebar
{
    NSView* container;
    NSRect frame;

    /* Main thread. */
    if (!w2sSplit) return;
    if (w2sSidebarObserver)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:w2sSidebarObserver];
        [w2sSidebarObserver release];
        w2sSidebarObserver = nil;
    }
    [w2sSidebarTarget release];
    w2sSidebarTarget = nil;

    frame = [self frame];
    container = [w2sContainer retain];
    [self setContentViewController:nil];
    [container removeFromSuperview];
    [self setContentView:container];
    [container release];
    [w2sSplit release];
    w2sSplit = nil;
    [self setFrameAndWineFrame:frame];
    [self w2sLayoutWineView];
    [self w2sDropChromeIfUnused];
}

/* where the app's layout has the pane beside its tree (not while it is hidden);
   narrower than the sidebar's minimum, the app's splitter follows the sidebar */
- (void) w2sSetSidebarWidth:(NSNumber*)width
{
    NSSplitViewItem* sideItem = [[w2sSplit splitViewItems] firstObject];
    CGFloat want = [width doubleValue], actual;

    if (!w2sSplit || !width || [sideItem isCollapsed]) return;
    /* never below the minimum: there AppKit hides the sidebar instead (under
       half of it) */
    if ([sideItem minimumThickness] > 0) want = MAX(want, [sideItem minimumThickness]);
    w2sSidebarSetting = YES;
    [[w2sSplit splitView] setPosition:want ofDividerAtIndex:0];
    w2sSidebarSetting = NO;
    actual = NSWidth([[[sideItem viewController] view] frame]);
    if (fabs(actual - [width doubleValue]) > 1 && [w2sSidebarTarget respondsToSelector:@selector(w2sSidebarResized:)])
        [w2sSidebarTarget performSelector:@selector(w2sSidebarResized:) withObject:@(actual)];
}

/* the toolbar's items changed: room for them beside wine's content */
- (void) w2sSetExtraWidth:(NSNumber*)number
{
    CGFloat extra = MAX([number doubleValue], 0);
    NSRect content;

    if (!w2sChrome || extra == w2sLeading + w2sTrailing) return;
    content = [self contentRectForFrameRect:[self frame]];  /* with the old margins */
    w2sLeading = floor(extra / 2);
    w2sTrailing = extra - w2sLeading;
    [self setFrameAndWineFrame:[self frameRectForContentRect:content]];
    [self w2sLayoutWineView];
}

- (void) w2sChromeChanged
{
    CGFloat top;

    if (!w2sChrome) return;
    top = NSHeight([self frame]) - NSMaxY([self contentLayoutRect]);
    if (top > 0 && top < 200) w2sTop = top;
    [self w2sLayoutWineView];
}

static BOOL w2s_native_ui;

/* the windows titled before the names or the native UI were known */
+ (void) w2sRetitle
{
    for (NSWindow* window in [NSApp windows])
    {
        BOOL edited;
        NSString* title;

        if (![window isKindOfClass:[WineWindow class]]) continue;
        title = macdrv_w2s_window_title([window title], &edited);
        if (![title isEqualToString:[window title]]) [window setTitle:title];
        else if (!edited) continue;
        if (edited) [window setDocumentEdited:YES];
        if ([window isVisible] && ![window isExcludedFromWindowsMenu])
            [NSApp changeWindowsItem:window title:title filename:NO];
    }
}

+ (void) w2sNativeUIOn
{
    if (w2s_native_ui) return;
    w2s_native_ui = TRUE;
    [self w2sRetitle];
}

+ (void) w2sAddAppName:(NSString*)name
{
    NSString* folded = mnc_fold(name);

    if (![folded length]) return;
    if (!mnc_app_names) mnc_app_names = [[NSMutableSet alloc] init];
    if ([mnc_app_names containsObject:folded]) return;
    [mnc_app_names addObject:folded];
    /* "Wine Wordpad": the program is Wordpad to a Mac, and the end of a title has either */
    if ([folded hasPrefix:@"wine "] && [folded length] > 8) [mnc_app_names addObject:[folded substringFromIndex:5]];
    [self w2sRetitle];
}

+ (void) w2sAddAboutText:(NSString*)text
{
    NSString* folded = mnc_fold(text);

    if ([folded length] < 4) return;
    if (!mnc_about_texts) mnc_about_texts = [[NSMutableSet alloc] init];
    if ([mnc_about_texts containsObject:folded]) return;
    [mnc_about_texts addObject:folded];
    [self w2sRetitle];
}

@end

bool macdrv_w2s_native_ui(void)
{
    return w2s_native_ui;
}

/***********************************************************************
 *              macdrv_w2s_window_title
 *
 * A Win32 window's title as its Mac window shows it. The mark a Win32 app
 * puts in its title for unsaved changes ("*name - App", "name* - App",
 * "name*") is the dot in a Mac window's close button instead (HIG, Windows).
 * Only with the native UI on; the Win32 title (GetWindowText) keeps it.
 */
/* "name" or "name - Program", where the program's own name is the program's: a Mac window is
 * titled with its document (HIG, Toolbars: don't title windows with your app name). The program's
 * names are its file name, its product name and description, and what its About item says
 * ("About Wine Wordpad", "À propos de Bloc-notes"). Only the end of the title, and only those. */
static NSMutableSet* mnc_app_names;      /* folded: exact or as the end of the suffix ("wine wordpad" for "wordpad") */
static NSMutableSet* mnc_about_texts;    /* folded: the suffix is part of one */

static NSString* mnc_fold(NSString* s)
{
    return [[s stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString* mnc_without_app(NSString* title)
{
    NSRange dash = [title rangeOfString:@" - " options:NSBackwardsSearch];
    NSString* suffix;
    NSRange tag;
    NSString* folded;

    if (!w2s_native_ui || dash.location == NSNotFound || dash.location == 0) return title;
    suffix = [title substringFromIndex:NSMaxRange(dash)];
    /* "Notepad++ [Administrator]": a tag after the name goes with it */
    tag = [suffix rangeOfString:@" [" options:NSBackwardsSearch];
    if (tag.location != NSNotFound && [suffix hasSuffix:@"]"]) suffix = [suffix substringToIndex:tag.location];
    folded = mnc_fold(suffix);
    if (![folded length]) return title;

    for (NSString* name in mnc_app_names)
        if ([folded isEqualToString:name] || ([name length] >= 4 && [folded hasSuffix:[@" " stringByAppendingString:name]]))
            return [title substringToIndex:dash.location];
    if ([folded length] >= 4)
        for (NSString* text in mnc_about_texts)
            if ([text rangeOfString:folded].location != NSNotFound) return [title substringToIndex:dash.location];
    return title;
}

static NSString* mnc_edit_mark(NSString* title, BOOL* edited)
{
    NSUInteger length = [title length];
    NSRange dash;

    *edited = FALSE;
    if (!w2s_native_ui || length < 2) return title;
    if ([title characterAtIndex:0] == '*')
    {
        *edited = TRUE;
        return [[title substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    dash = [title rangeOfString:@" - "];
    if (dash.location == NSNotFound) dash = [title rangeOfString:@" \u2014 "];
    if (dash.location != NSNotFound && dash.location > 1 && [title characterAtIndex:dash.location - 1] == '*')
    {
        *edited = TRUE;
        return [title stringByReplacingCharactersInRange:NSMakeRange(dash.location - 1, 1) withString:@""];
    }
    if ([title characterAtIndex:length - 1] == '*')
    {
        *edited = TRUE;
        return [[title substringToIndex:length - 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return title;
}

NSString *macdrv_w2s_window_title(NSString *title, BOOL *edited)
{
    return mnc_without_app(mnc_edit_mark(title, edited));
}

void macdrv_w2s_add_app_name(const unsigned short* name, size_t length)
{
    NSString* string = [NSString stringWithCharacters:name length:length];

    OnMainThreadAsync(^{ [WineWindow w2sAddAppName:string]; });
}
