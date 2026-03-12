/**
 * Windows API header module
 *
 * Translated from MinGW API for MS-Windows 3.10
 *
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source: $(DRUNTIMESRC core/sys/windows/_basetyps.d)
 */
module urt.internal.sys.windows.basetyps;
version (Windows):

import urt.internal.sys.windows.windef, urt.internal.sys.windows.basetsd;

align(1) struct GUID {  // size is 16
    align(1):
    DWORD   Data1;
    WORD    Data2;
    WORD    Data3;
    BYTE[8] Data4;
}
alias GUID UUID, /*IID, CLSID, */FMTID, uuid_t;
alias IID = const(GUID);
alias CLSID = const(GUID);

alias GUID* LPGUID, LPCLSID, LPIID;
alias const(GUID)* LPCGUID, REFGUID, REFIID, REFCLSID, REFFMTID;
alias uint error_status_t, PROPID;
