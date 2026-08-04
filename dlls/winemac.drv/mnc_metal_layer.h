/*
 * MNC HACK 14: present-notification CAMetalLayer subclass for the
 * D3DMetal GPTK bridge.
 *
 * Without this layer, GPTK D3DMetal renders into a plain CAMetalLayer
 * that wine has no insight into — wine never learns when GPTK presents
 * a frame, so the per-swapchain client view never gets unhidden and
 * the visible window stays empty. MNCMetalLayer is a CAMetalLayer
 * subclass whose -nextDrawable override pushes a Cocoa event back
 * into the wineserver event queue carrying the client_surface
 * pointer attached to the parent WineContentView; the event handler
 * calls into wine's win32u client_surface_present() machinery which
 * does the make-visible step.
 *
 * It subclasses WineMetalLayer rather than CAMetalLayer so a single
 * backing layer serves both backends: this override fires for views the
 * D3DMetal bridge tagged, then chains to WineMetalLayer, which fires for
 * DXMT-tagged views.  A view tagged by neither falls through both and
 * behaves exactly like a stock CAMetalLayer.
 */

#ifndef __WINE_MNC_METAL_LAYER_H
#define __WINE_MNC_METAL_LAYER_H

#if defined(__x86_64__)

#import <QuartzCore/QuartzCore.h>
#import "dxmt_objc.h"

@interface MNCMetalLayer : WineMetalLayer
@end

#endif

#endif /* __WINE_MNC_METAL_LAYER_H */
