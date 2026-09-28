/*
 * MACDRV Cocoa window declarations
 *
 * Copyright 2011, 2012, 2013 Ken Thomases for CodeWeavers Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>


@class WineEventQueue;


@interface WineWindow : NSPanel <NSWindowDelegate>
{
    BOOL disabled;
    BOOL noForeground;
    BOOL preventsAppActivation;
    BOOL floating;
    BOOL resizable;
    BOOL maximized;
    BOOL fullscreen;
    BOOL pendingMinimize;
    BOOL pendingOrderOut;
    BOOL savedVisibleState;
    BOOL drawnSinceShown;
    BOOL closing;
    WineWindow* latentParentWindow;
    NSMutableArray* latentChildWindows;

    void* hwnd;
    WineEventQueue* queue;

    NSRect wineFrame;
    NSRect roundedWineFrame;

    BOOL shapeChangedSinceLastDraw;

    BOOL usePerPixelAlpha;

    NSUInteger lastModifierFlags;

    NSRect frameAtResizeStart;
    BOOL resizingFromLeft, resizingFromTop;

    void* himc;
    BOOL commandDone;

    NSSize savedContentMinSize;
    NSSize savedContentMaxSize;

    BOOL enteringFullScreen;
    BOOL exitingFullScreen;
    NSRect nonFullscreenFrame;
    NSTimeInterval enteredFullScreenTime;

    int draggingPhase;
    NSPoint dragStartPosition;
    NSPoint dragWindowStartPosition;

    NSTimeInterval lastDockIconSnapshot;

    BOOL allowKeyRepeats;

    BOOL ignore_windowDeminiaturize;
    BOOL ignore_windowResize;
    BOOL fakingClose;

    CAShapeLayer* contentViewMaskLayer;

    /* MNC Win32-to-SwiftUI: a native toolbar in the window frame (mnc_w2s.m).
       The window's content is then a plain container, wine's view sits in it
       below the titlebar and toolbar, and the window is wider than wine's
       content by w2sLeading + w2sTrailing (room for the toolbar's items) and
       taller by w2sTop (the titlebar and toolbar over a full-size content view). */
    BOOL w2sChrome;
    NSView* w2sWineView;
    CGFloat w2sLeading, w2sTrailing, w2sTop;
}

@property (retain, readonly, nonatomic) WineEventQueue* queue;
@property (readonly, nonatomic) BOOL disabled;
@property (readonly, nonatomic) BOOL noForeground;
@property (readonly, nonatomic) BOOL preventsAppActivation;
@property (readonly, nonatomic) BOOL floating;
@property (readonly, getter=isFullscreen, nonatomic) BOOL fullscreen;
@property (readonly, getter=isFakingClose, nonatomic) BOOL fakingClose;
@property (readonly, nonatomic) NSRect wine_fractionalFrame;

/* Whether this window, when ordered in and not miniaturized, would appear to
   the user on-screen. That means it has a non-zero size and is not empty-
   shaped, or has a child window that meets those criteria. */
@property (readonly, nonatomic) BOOL presentsVisibleContent;

    - (NSInteger) minimumLevelForActive:(BOOL)active;
    - (void) updateFullscreen;

    - (void) postKeyEvent:(NSEvent *)theEvent;
    - (void) postBroughtForwardEvent;

    - (WineWindow*) ancestorWineWindow;

    - (void) updateForCursorClipping;

    - (void) setRetinaMode:(BOOL)mode;

    /* the view wine draws in: the content view, or the one under a native toolbar */
    - (NSView*) wineContentView;

@end

/* MNC Win32-to-SwiftUI: a native toolbar in the window frame (mnc_w2s.m) */
@interface WineWindow (W2SChrome)
    /* spec: "toolbar" (NSToolbar), "style" (NSWindowToolbarStyle), "extraWidth"
       (points the window is wider than wine's content, split both sides) */
    - (void) w2sAttachToolbar:(NSDictionary*)spec;
    - (void) w2sDetachToolbar;
    - (void) w2sSetExtraWidth:(NSNumber*)extra;
    /* after the titlebar changed */
    - (void) w2sChromeChanged;
@end


/* MNC Win32-to-SwiftUI: holds the native control of one translated Win32 control (mnc_w2s.m). */
@interface WineW2SHostView : NSView
{
    WineEventQueue* queue;
    uint64_t hwnd;
    unsigned int message;
    NSRect wineFrame;       /* the control's rectangle */
    CGFloat outsetTop;      /* how far the native control reaches above it */
    BOOL behind;            /* below the other native controls (a container) */
}

@property (readonly, nonatomic) uint64_t hwnd;
@property (readonly, nonatomic) unsigned int message;

    - (instancetype) initWithQueue:(WineEventQueue*)inQueue hwnd:(uint64_t)inHwnd message:(unsigned int)inMessage;
    - (WineEventQueue*) queue;
    /* for win32swiftui.so (performSelector:, main thread): a group box's title sits
       above its rectangle, and the box stays behind the controls it contains */
    - (void) w2sSetOutsetTop:(NSNumber*)top;
    - (void) w2sSetBehind:(NSNumber*)flag;
    - (BOOL) w2sBehind;
    - (void) w2sApplyFrame:(NSRect)frame;

@end

extern WineW2SHostView *macdrv_w2s_host_for_view(NSView *view);
extern BOOL macdrv_w2s_event_in_host(NSEvent *event);
extern BOOL macdrv_w2s_key_goes_to_wine(NSEvent *event, NSResponder *responder);
