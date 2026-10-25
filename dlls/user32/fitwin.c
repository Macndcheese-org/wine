/*
 * MNC: fit the main window of a DPI aware program to its controls in Retina mode
 *
 * A program that tells Windows it handles the DPI of the display lays its controls out for it, but
 * some pick the size of their main window in raw pixels all the same (FileZilla asks for 1200x950
 * whatever the DPI). At 192 DPI its controls are twice as big and no longer fit in that window: the
 * last of a row is cut off at the window's edge.
 *
 * A moment after such a window is made, look for controls that their parent cuts off. If there are,
 * the program sized its window in pixels that were made for 96 DPI: the window gets the size it would
 * have had on a 96 DPI display, in the same points, the size the DPI makes of it (or, if that is
 * not enough to show them, as large as they need), never past the work area. The program's layout
 * is then checked to have followed: if it did not, the window gets its size back.
 *
 * The check is off with MNC_FIT_WINDOW=0 in the environment, or HKCU\Software\Wine\Mac Driver\
 * FitWindow = "n", overridable per program under HKCU\Software\Wine\AppDefaults\<program.exe>\Mac Driver.
 */

#include <stdarg.h>

#include "windef.h"
#include "winbase.h"
#include "winreg.h"
#include "winternl.h"
#include "winuser.h"
#include "wine/debug.h"
#include "ntuser.h"
#include "user_private.h"

WINE_DEFAULT_DEBUG_CHANNEL(fitwin);

#define FIT_FIRST_DELAY   1200  /* ms: the program lays itself out after its window shows */
#define FIT_RETRY_DELAY   1000
#define FIT_VERIFY_DELAY   700
#define FIT_MAX_TRIES       40  /* a program may show its window long after it made it */
#define FIT_MIN_OVERFLOW    24  /* pixels at 96 DPI */

struct fit
{
    HWND hwnd;
    RECT orig;          /* the window's rectangle before it grew */
    SIZE over;          /* what was cut off then */
    int tries;
    BOOL grown;
};

static INIT_ONCE fit_once = INIT_ONCE_STATIC_INIT;
static BOOL fit_on;

static int bool_value( const WCHAR *value )
{
    if (!value[0]) return -1;
    return value[0] == 'y' || value[0] == 'Y' || value[0] == 't' || value[0] == 'T' || value[0] == '1';
}

static int registry_switch( const WCHAR *path )
{
    WCHAR value[8];
    DWORD size = sizeof(value);

    if (RegGetValueW( HKEY_CURRENT_USER, path, L"FitWindow", RRF_RT_REG_SZ, NULL, value, &size )) return -1;
    return bool_value( value );
}

static BOOL CALLBACK fit_init( INIT_ONCE *once, void *param, void **context )
{
    WCHAR value[8], module[MAX_PATH], path[MAX_PATH + 64], *exe;
    int on;

    fit_on = TRUE;
    if (GetEnvironmentVariableW( L"MNC_FIT_WINDOW", value, ARRAY_SIZE(value) ) &&
        (on = bool_value( value )) != -1)
    {
        fit_on = on;
        return TRUE;
    }
    if (GetModuleFileNameW( NULL, module, MAX_PATH ) && (exe = wcsrchr( module, '\\' )))
    {
        wcscpy( path, L"Software\\Wine\\AppDefaults\\" );
        wcscat( path, exe + 1 );
        wcscat( path, L"\\Mac Driver" );
        if ((on = registry_switch( path )) != -1)
        {
            fit_on = on;
            return TRUE;
        }
    }
    if ((on = registry_switch( L"Software\\Wine\\Mac Driver" )) != -1) fit_on = on;
    return TRUE;
}

/* parents that hold more than they show on purpose: their children may lie outside them */
static BOOL holds_more_than_it_shows( HWND hwnd )
{
    static const WCHAR *const classes[] =
    {
        L"SysListView32", L"SysTreeView32", L"SysHeader32", L"MDIClient", L"ReBarWindow32",
        L"ToolbarWindow32", L"ComboLBox", L"ScrollBar",
    };
    WCHAR class[64];
    unsigned int i;

    if (GetWindowLongW( hwnd, GWL_STYLE ) & (WS_HSCROLL | WS_VSCROLL)) return TRUE;
    if (!GetClassNameW( hwnd, class, ARRAY_SIZE(class) )) return FALSE;
    for (i = 0; i < ARRAY_SIZE(classes); i++)
        if (!wcsicmp( class, classes[i] )) return TRUE;
    return FALSE;
}

/* how far the visible controls under parent reach past their own parent's client area */
static void measure( HWND parent, SIZE *over, int depth )
{
    RECT client;
    HWND child;

    if (depth > 12 || holds_more_than_it_shows( parent )) return;
    GetClientRect( parent, &client );
    for (child = GetWindow( parent, GW_CHILD ); child; child = GetWindow( child, GW_HWNDNEXT ))
    {
        RECT rc;

        if (!(GetWindowLongW( child, GWL_STYLE ) & WS_VISIBLE)) continue;
        if (!GetWindowRect( child, &rc ) || IsRectEmpty( &rc )) continue;
        MapWindowPoints( NULL, parent, (POINT *)&rc, 2 );
        /* one far outside its parent is out of the way on purpose; one just past its edge is cut off */
        if (rc.left < client.right * 2 && rc.top < client.bottom * 2)
        {
            over->cx = max( over->cx, rc.right - client.right );
            over->cy = max( over->cy, rc.bottom - client.bottom );
        }
        measure( child, over, depth + 1 );
    }
}

static BOOL fitting_window( HWND hwnd )
{
    return IsWindow( hwnd ) && IsWindowVisible( hwnd ) && !IsIconic( hwnd ) && !IsZoomed( hwnd );
}

static void CALLBACK fit_timer( void *param, BOOLEAN fired );

static void fit_schedule( struct fit *fit, DWORD delay )
{
    HANDLE timer;

    if (CreateTimerQueueTimer( &timer, NULL, fit_timer, fit, delay, 0, WT_EXECUTEONLYONCE )) return;
    HeapFree( GetProcessHeap(), 0, fit );
}

static void CALLBACK fit_timer( void *param, BOOLEAN fired )
{
    struct fit *fit = param;
    unsigned int min_over = MulDiv( FIT_MIN_OVERFLOW, GetDpiForSystem(), 96 );
    SIZE over = { 0, 0 };
    MONITORINFO mi = { sizeof(mi) };
    RECT rc;
    int width, height, x, y;

    if (!IsWindow( fit->hwnd )) goto done;
    if (!fitting_window( fit->hwnd ))
    {
        if (!fit->grown && ++fit->tries < FIT_MAX_TRIES)
        {
            fit_schedule( fit, FIT_RETRY_DELAY );
            return;
        }
        goto done;
    }
    measure( fit->hwnd, &over, 0 );
    TRACE( "%p: cut off by %ldx%ld (grown %d)\n", fit->hwnd, over.cx, over.cy, fit->grown );

    if (fit->grown)
    {
        /* the layout followed if what was cut off is mostly in view now */
        if (over.cx > fit->over.cx / 2 || over.cy > fit->over.cy / 2)
        {
            TRACE( "%p: still cut off by %ldx%ld, back to its size\n", fit->hwnd, over.cx, over.cy );
            NtUserSetWindowPos( fit->hwnd, NULL, fit->orig.left, fit->orig.top, fit->orig.right - fit->orig.left,
                                fit->orig.bottom - fit->orig.top, SWP_NOZORDER | SWP_NOACTIVATE );
        }
        goto done;
    }

    if (over.cx < min_over && over.cy < min_over) goto done;
    if (!GetWindowRect( fit->hwnd, &rc ) || !GetMonitorInfoW( MonitorFromWindow( fit->hwnd, MONITOR_DEFAULTTOPRIMARY ), &mi ))
        goto done;
    /* the window as the DPI makes it (the same in points as at 96 DPI), or what the controls need if that is more */
    width = rc.right - rc.left;
    height = rc.bottom - rc.top;
    if (over.cx >= min_over) width = max( width + over.cx + min_over / 3, MulDiv( width, GetDpiForSystem(), 96 ) );
    else width = MulDiv( width, GetDpiForSystem(), 96 );
    if (over.cy >= min_over) height = max( height + over.cy + min_over / 3, MulDiv( height, GetDpiForSystem(), 96 ) );
    else height = MulDiv( height, GetDpiForSystem(), 96 );
    width = min( width, mi.rcWork.right - mi.rcWork.left );
    height = min( height, mi.rcWork.bottom - mi.rcWork.top );
    if (width <= rc.right - rc.left && height <= rc.bottom - rc.top) goto done;
    x = min( rc.left, mi.rcWork.right - width );
    y = min( rc.top, mi.rcWork.bottom - height );
    x = max( x, mi.rcWork.left );
    y = max( y, mi.rcWork.top );

    TRACE( "%p: controls cut off by %ldx%ld, window %ldx%ld -> %dx%d\n", fit->hwnd, over.cx, over.cy,
           rc.right - rc.left, rc.bottom - rc.top, width, height );
    fit->orig = rc;
    fit->over = over;
    fit->grown = TRUE;
    NtUserSetWindowPos( fit->hwnd, NULL, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE );
    fit_schedule( fit, FIT_VERIFY_DELAY );
    return;

done:
    HeapFree( GetProcessHeap(), 0, fit );
}

void mnc_fit_window_created( HWND hwnd )
{
    LONG style = GetWindowLongW( hwnd, GWL_STYLE );
    struct fit *fit;

    /* a main window: a frame that can be sized, with a title, and no owner */
    if (style & (WS_CHILD | WS_POPUP)) return;
    if ((style & WS_CAPTION) != WS_CAPTION || !(style & WS_THICKFRAME)) return;
    if (GetWindow( hwnd, GW_OWNER )) return;
    /* only where the DPI is raised and the program handles it: it would be virtualized otherwise */
    if (GetDpiForSystem() <= 96) return;
    InitOnceExecuteOnce( &fit_once, fit_init, NULL, NULL );
    if (!fit_on) return;

    if (!(fit = HeapAlloc( GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*fit) ))) return;
    fit->hwnd = hwnd;
    fit_schedule( fit, FIT_FIRST_DELAY );
}
