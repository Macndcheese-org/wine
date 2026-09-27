/*
 * MNC Win32-to-SwiftUI: hand controls and message boxes to win32swiftui.dll
 *
 * When the native UI switch is on, every window created through CreateWindowEx
 * is offered to win32swiftui.dll, which translates the standard controls into
 * SwiftUI views, and MessageBox is offered to it before wine's own dialog.
 * With the switch off, or without the DLL, nothing here does anything.
 *
 * The switch is on by default. Turn it off with WINE_MNC_NATIVE_UI=0 in the
 * environment, or HKCU\Software\Wine\Mac Driver\NativeUI = "n", overridable per
 * program under HKCU\Software\Wine\AppDefaults\<program.exe>\Mac Driver.
 * Wine's own background processes stay off unless a setting names them.
 */

#include <stdarg.h>

#include "windef.h"
#include "winbase.h"
#include "winreg.h"
#include "winternl.h"
#include "user_private.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(w2s);

static INIT_ONCE w2s_once = INIT_ONCE_STATIC_INIT;
static void (WINAPI *pW2SWindowCreated)( HWND hwnd );
static BOOL (WINAPI *pW2SMessageBox)( const MSGBOXPARAMSW *params, INT *ret );
static BOOL (WINAPI *pW2STrackPopupMenu)( HMENU menu, UINT flags, INT x, INT y, HWND hwnd, TPMPARAMS *params, INT *ret );

static int bool_value( const WCHAR *value )
{
    if (!value[0]) return -1;
    return value[0] == 'y' || value[0] == 'Y' || value[0] == 't' || value[0] == 'T' || value[0] == '1';
}

static int registry_switch( HKEY root, const WCHAR *path )
{
    WCHAR value[8];
    DWORD size = sizeof(value);

    if (RegGetValueW( root, path, L"NativeUI", RRF_RT_REG_SZ, NULL, value, &size )) return -1;
    return bool_value( value );
}

/* Wine's services and the helper processes of Chromium-based apps (Steam's
 * steamwebhelper renderers, Electron) have no controls worth translating, and
 * loading SwiftUI into each of them would cost memory for nothing. */
static BOOL background_process( const WCHAR *exe )
{
    static const WCHAR *names[] =
    {
        L"conhost.exe", L"explorer.exe", L"plugplay.exe", L"rpcss.exe", L"services.exe",
        L"start.exe", L"svchost.exe", L"wineboot.exe", L"winedevice.exe",
    };
    unsigned int i;

    for (i = 0; i < ARRAY_SIZE(names); i++) if (!wcsicmp( exe, names[i] )) return TRUE;
    return wcsstr( GetCommandLineW(), L" --type=" ) != NULL;
}

static BOOL w2s_enabled(void)
{
    WCHAR value[8], module[MAX_PATH], path[MAX_PATH + 64], *exe = NULL;
    int on;

    if (GetEnvironmentVariableW( L"WINE_MNC_NATIVE_UI", value, ARRAY_SIZE(value) ) &&
        (on = bool_value( value )) != -1)
        return on;

    if (GetModuleFileNameW( NULL, module, MAX_PATH ) && (exe = wcsrchr( module, '\\' )))
    {
        exe++;
        wcscpy( path, L"Software\\Wine\\AppDefaults\\" );
        wcscat( path, exe );
        wcscat( path, L"\\Mac Driver" );
        if ((on = registry_switch( HKEY_CURRENT_USER, path )) != -1) return on;
    }

    if (exe && background_process( exe )) return FALSE;
    return registry_switch( HKEY_CURRENT_USER, L"Software\\Wine\\Mac Driver" ) != 0;
}

static BOOL CALLBACK w2s_init( INIT_ONCE *once, void *param, void **context )
{
    HMODULE module;

    if (!w2s_enabled()) return TRUE;
    if (!(module = LoadLibraryW( L"win32swiftui.dll" )))
    {
        WARN( "native UI is on but win32swiftui.dll can't be loaded (%lu)\n", GetLastError() );
        return TRUE;
    }
    pW2SWindowCreated = (void *)GetProcAddress( module, "W2SWindowCreated" );
    pW2SMessageBox = (void *)GetProcAddress( module, "W2SMessageBox" );
    pW2STrackPopupMenu = (void *)GetProcAddress( module, "W2STrackPopupMenu" );
    TRACE( "win32swiftui.dll loaded: %p %p\n", pW2SWindowCreated, pW2SMessageBox );
    return TRUE;
}

void w2s_window_created( HWND hwnd )
{
    InitOnceExecuteOnce( &w2s_once, w2s_init, NULL, NULL );
    if (pW2SWindowCreated) pW2SWindowCreated( hwnd );
}

BOOL w2s_message_box( const MSGBOXPARAMSW *params, INT *ret )
{
    InitOnceExecuteOnce( &w2s_once, w2s_init, NULL, NULL );
    return pW2SMessageBox && pW2SMessageBox( params, ret );
}

BOOL w2s_track_popup_menu( HMENU menu, UINT flags, INT x, INT y, HWND hwnd, TPMPARAMS *params, INT *ret )
{
    InitOnceExecuteOnce( &w2s_once, w2s_init, NULL, NULL );
    return pW2STrackPopupMenu && pW2STrackPopupMenu( menu, flags, x, y, hwnd, params, ret );
}
