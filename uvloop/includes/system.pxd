IF UNAME_SYSNAME == "Windows":
    include "windows.pxi"
ELSE:
    include "posix.pxi"
