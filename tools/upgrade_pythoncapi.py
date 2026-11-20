#!/usr/bin/env python3
import argparse
import os
import re
import urllib.request
import sys


MIN_PYTHON = (2, 7)


PYTHONCAPI_COMPAT_URL = ('https://raw.githubusercontent.com/python/'
                         'pythoncapi-compat/main/pythoncapi_compat.h')
PYTHONCAPI_COMPAT_H = 'pythoncapi_compat.h'
INCLUDE_PYTHONCAPI_COMPAT = f'#include "{PYTHONCAPI_COMPAT_H}"'
INCLUDE_PYTHONCAPI_COMPAT2 = f'#include <{PYTHONCAPI_COMPAT_H}>'

C_FILE_EXT = (
    # C language
    ".c", ".h",
    # C++ language
    ".cc", ".cpp", ".cxx", ".hpp",
)
IGNORE_DIRS = (".git", ".tox")


# Match spaces but not newline characters.
# Similar to \s but exclude newline characters and only look for ASCII spaces
SPACE_REGEX = r'[ \t\f\v]'
# Match the end of a line: newline characters of a single line
NEWLINE_REGEX = r'(?:\n|\r|\r\n)'
# Match the indentation at the beginning of a line
INDENTATION_REGEX = fr'^{SPACE_REGEX}*'


# Match a C identifier: 'identifier', 'var_3', 'NameCamelCase', '_var'
# Use \b to only match a full word: match "a_b", but not just "b" in "a_b".
ID_REGEX = r'\b[a-zA-Z_][a-zA-Z0-9_]*\b'
# Match 'array[3]'
SUBEXPR_REGEX = fr'{ID_REGEX}(?:\[[^]]+\])*'
# Match a C expression like "frame", "frame.attr", "obj->attr" or "*obj".
# Don't match functions calls like "func()".
EXPR_REGEX = (fr"\*?"  # "*" prefix
              fr"{SUBEXPR_REGEX}"  # "var"
              fr"(?:(?:->|\.){SUBEXPR_REGEX})*")  # "->attr" or ".attr"

# # Match 'PyObject *var' and 'struct MyStruct* var'
TYPE_PTR_REGEX = fr'{ID_REGEX} *\*'

# Match '(PyObject*)' and nothing
OPT_CAST_REGEX = fr'(?:\({TYPE_PTR_REGEX} *\){SPACE_REGEX}*)?'


def same_indentation(group):
    # the regex must have re.MULTILINE flag
    return fr'{SPACE_REGEX}*(?:{NEWLINE_REGEX}{group})?'


def get_member_regex_str(member):
    # Match "var->member".
    return fr'\b({EXPR_REGEX}) *-> *{member}\b'


def get_member_regex(member):
    # Match "var->member" (get).
    # Don't match "var->member = value" (set).
    # Don't match "Py_CLEAR(var->member)".
    # Only "Py_CLEAR(" exact string is excluded.
    regex = (r'(?<!Py_CLEAR\()'
             + get_member_regex_str(member)
             + r'(?!\s*=\s*)')
    return re.compile(regex)


def assign_regex_str(var, expr):
    # Match "var = expr;".
    return fr'{var} *= *{expr}\s*;'


def set_member_regex(member):
    # Match "var->member = expr;".
    regex = assign_regex_str(get_member_regex_str(member), r'([^=].*)')
    return re.compile(regex)


def call_assign_regex(name):
    # Match "Py_TYPE(expr) = expr;".
    # Don't match "assert(Py_TYPE(expr) == expr);".
    # Tolerate spaces
    regex = fr'{name} *\( *(.+) *\) *= *([^=].*) *;'
    return re.compile(regex)


def is_c_filename(filename):
    return filename.endswith(C_FILE_EXT)


class Operation:
    NAME = "<name>"
    REPLACE = ()
    NEED_PYTHONCAPI_COMPAT = False

    def __init__(self, patcher):
        self.patcher = patcher

    def patch(self, content):
        old_content = content
        for regex, replace in self.REPLACE:
            content = regex.sub(replace, content)
        if content != old_content and self.NEED_PYTHONCAPI_COMPAT:
            content = self.patcher.add_pythoncapi_compat(content)
        return content


class Py_TYPE(Operation):
    NAME = "Py_TYPE"
    REPLACE = (
        (get_member_regex('ob_type'), r'Py_TYPE(\1)'),
    )
    # Py_TYPE() was added to Python 2.6.


class Py_SIZE(Operation):
    NAME = "Py_SIZE"
    REPLACE = (
        (get_member_regex('ob_size'), r'Py_SIZE(\1)'),
    )
    # Py_SIZE() was added to Python 2.6.


class Py_REFCNT(Operation):
    NAME = "Py_REFCNT"
    REPLACE = (
        (get_member_regex('ob_refcnt'), r'Py_REFCNT(\1)'),
    )
    # Py_REFCNT() was added to Python 2.6.


class Py_SET_TYPE(Operation):
    NAME = "Py_SET_TYPE"
    REPLACE = (
        (call_assign_regex('Py_TYPE'), r'Py_SET_TYPE(\1, \2);'),
        (set_member_regex('ob_type'), r'Py_SET_TYPE(\1, \2);'),
    )
    # Need Py_SET_TYPE(): new in Python 3.9.
    NEED_PYTHONCAPI_COMPAT = (MIN_PYTHON < (3, 9))


class Py_SET_SIZE(Operation):
    NAME = "Py_SET_SIZE"
    REPLACE = (
        (call_assign_regex('Py_SIZE'), r'Py_SET_SIZE(\1, \2);'),
        (set_member_regex('ob_size'), r'Py_SET_SIZE(\1, \2);'),
    )
    # Need Py_SET_SIZE(): new in Python 3.9.
    NEED_PYTHONCAPI_COMPAT = (MIN_PYTHON < (3, 9))


class Py_SET_REFCNT(Operation):
    NAME = "Py_SET_REFCNT"
    REPLACE = (
        (call_assign_regex('Py_REFCNT'), r'Py_SET_REFCNT(\1, \2);'),
        (set_member_regex('ob_refcnt'), r'Py_SET_REFCNT(\1, \2);'),
    )
    # Need Py_SET_REFCNT(): new in Python 3.9.
    NEED_PYTHONCAPI_COMPAT = (MIN_PYTHON < (3, 9))


class PyObject_NEW(Operation):
    NAME = "PyObject_NEW"
    # In Python 3.9, the PyObject_NEW() macro becomes an alias to the
    # PyObject_New() macro, and the PyObject_NEW_VAR() macro becomes an alias
    # to the PyObject_NewVar() macro.
    REPLACE = (
        (re.compile(r"\bPyObject_NEW\b( *\()"), r'PyObject_New\1'),
        (re.compile(r"\bPyObject_NEW_VAR\b( *\()"), r'PyObject_NewVar\1'),
    )


class PyMem_MALLOC(Operation):
    NAME = "PyMem_MALLOC"
    # In Python 3.9, the PyObject_NEW() macro becomes an alias to the
    # PyObject_New() macro, and the PyObject_NEW_VAR() macro becomes an alias
    # to the PyObject_NewVar() macro.

    REPLACE = (
        (re.compile(r"\bPyMem_MALLOC\b( *\()"), r'PyMem_Malloc\1'),
        (re.compile(r"\bPyMem_REALLOC\b( *\()"), r'PyMem_Realloc\1'),
        (re.compile(r"\bPyMem_FREE\b( *\()"), r'PyMem_Free\1'),
        (re.compile(r"\bPyMem_Del\b( *\()"), r'PyMem_Free\1'),
        (re.compile(r"\bPyMem_DEL\b( *\()"), r'PyMem_Free\1'),
    )


class PyObject_MALLOC(Operation):
    NAME = "PyObject_MALLOC"
    # In Python 3.9, the PyObject_NEW() macro becomes an alias to the
    # PyObject_New() macro, and the PyObject_NEW_VAR() macro becomes an alias
    # to the PyObject_NewVar() macro.

    REPLACE = (
        (re.compile(r"\bPyObject_MALLOC\b( *\()"), r'PyObject_Malloc\1'),
        (re.compile(r"\bPyObject_REALLOC\b( *\()"), r'PyObject_Realloc\1'),
        (re.compile(r"\bPyObject_FREE\b( *\()"), r'PyObject_Free\1'),
        (re.compile(r"\bPyObject_Del\b( *\()"), r'PyObject_Free\1'),
        (re.compile(r"\bPyObject_DEL\b( *\()"), r'PyObject_Free\1'),
    )


class PyFrame_GetBack(Operation):
    NAME = "PyFrame_GetBack"
    REPLACE = (
        (get_member_regex('f_back'), r'_PyFrame_GetBackBorrow(\1)'),
    )
    # Need _PyFrame_GetBackBorrow() (PyFrame_GetBack() is new in Python 3.9)
    NEED_PYTHONCAPI_COMPAT = (MIN_PYTHON < (3, 9))


class PyFrame_GetCode(Operation):
    NAME = "PyFrame_GetCode"

    REPLACE = (
        (get_member_regex('f_code'), r'_PyFrame_GetCodeBorrow(\1)'),
    )
    # Need _PyFrame_GetCodeBorrow() (PyFrame_GetCode() is new in Python 3.9)
    NEED_PYTHONCAPI_COMPAT = (MIN_PYTHON < (3, 9))


class PyThreadState_GetInterpreter(Operation):
    NAME = "PyThreadState_GetInterpreter"
    REPLACE = (
        (get_member_regex('interp'), r'PyThreadState_GetInterpreter(\1)'),
    )
    # Need PyThreadState_GetInterpreter() (new in Python 3.9)
    NEED_PYTHONCAPI_COMPAT = (MIN_PYTHON < (3, 9))


class PyThreadState_GetFrame(Operation):
    NAME = "PyThreadState_GetFrame"
    REPLACE = (
        (get_member_regex('frame'), r'_PyThreadState_GetFrameBorrow(\1)'),
    )
    # Need _PyThreadState_GetFrameBorrow()
    # (PyThreadState_GetFrame() is new in Python 3.9)
    NEED_PYTHONCAPI_COMPAT = (MIN_PYTHON < (3, 9))


class Py_NewRef(Operation):
    NAME = "Py_NewRef"
    REPLACE = (
        # "Py_INCREF(x); return x;" => "return Py_NewRef(x);"
        # "Py_XINCREF(x); return x;" => "return Py_XNewRef(x);"
        # The two statements must be at the same indentation, otherwise the
        # regex does not match.
        (re.compile(fr'({INDENTATION_REGEX})'
                    + fr'Py_(X?)INCREF\(({EXPR_REGEX})\)\s*;'
                    + same_indentation(r'\1')
                    + fr'return {OPT_CAST_REGEX}\3;',
                    re.MULTILINE),
         r'\1return Py_\2NewRef(\3);'),

        # Same regex than the previous one,
        # but the two statements are on the same line.
        (re.compile(fr'Py_(X?)INCREF\(({EXPR_REGEX})\)\s*;'
                    + fr'{SPACE_REGEX}*'
                    + fr'return {OPT_CAST_REGEX}\2;',
                    re.MULTILINE),
         r'return Py_\1NewRef(\2);'),

        # "Py_INCREF(x); y = x;" must be replaced before
        # "y = x; Py_INCREF(y);", to not miss consecutive
        # "Py_INCREF; assign; Py_INCREF; assign; ..." (see unit tests).

        # "Py_INCREF(x); y = x;" => "y = Py_NewRef(x)"
        # "Py_XINCREF(x); y = x;" => "y = Py_XNewRef(x)"
        # The two statements must have the same indentation, otherwise the
        # regex does not match.
        (re.compile(fr'({INDENTATION_REGEX})'
                    + fr'Py_(X?)INCREF\(({EXPR_REGEX})\);'
                    + same_indentation(r'\1')
                    + assign_regex_str(fr'({EXPR_REGEX})',
                                       fr'{OPT_CAST_REGEX}\3'),
                    re.MULTILINE),
         r'\1\4 = Py_\2NewRef(\3);'),

        # Same regex than the previous one,
        # but the two statements are on the same line.
        (re.compile(fr'Py_(X?)INCREF\(({EXPR_REGEX})\);'
                    + fr'{SPACE_REGEX}*'
                    + assign_regex_str(fr'({EXPR_REGEX})',
                                       fr'{OPT_CAST_REGEX}\2')),
         r'\3 = Py_\1NewRef(\2);'),

        # "y = x; Py_INCREF(x);" => "y = Py_NewRef(x);"
        # "y = x; Py_INCREF(y);" => "y = Py_NewRef(x);"
        # "y = x; Py_XINCREF(x);" => "y = Py_XNewRef(x);"
        # "y = x; Py_XINCREF(y);" => "y = Py_XNewRef(x);"
        # "y = (PyObject*)x; Py_XINCREF(y);" => "y = Py_XNewRef(x);"
        # The two statements must have the same indentation, otherwise the
        # regex does not match.
        (re.compile(fr'({INDENTATION_REGEX})'
                    + assign_regex_str(fr'({EXPR_REGEX})',
                                       fr'{OPT_CAST_REGEX}({EXPR_REGEX})')
                    + same_indentation(r'\1')
                    + r'Py_(X?)INCREF\((?:\2|\3)\);',
                    re.MULTILINE),
         r'\1\2 = Py_\4NewRef(\3);'),

        # Same regex than the previous one,
        # but the two statements are on the same line.
        (re.compile(assign_regex_str(fr'({EXPR_REGEX})',
                                     fr'{OPT_CAST_REGEX}({EXPR_REGEX})')
                    + fr'{SPACE_REGEX}*'
                    + r'Py_(X?)INCREF\((?:\1|\2)\);'),
         r'\1 = Py_\3NewRef(\2);'),

        # "PyObject *var = x; Py_INCREF(x);" => "PyObject *var = Py_NewRef(x);"
        # The two statements must have the same indentation, otherwise the
        # regex does not match.
        (re.compile(fr'({INDENTATION_REGEX})'
                      # "type* var = expr;"
                    + assign_regex_str(fr'({TYPE_PTR_REGEX} *)({EXPR_REGEX})',
                                       fr'({OPT_CAST_REGEX})({EXPR_REGEX})')
                    + same_indentation(r'\1')
                      # "Py_INCREF(var);"
                    + r'Py_(X?)INCREF\((?:\3|\5)\);',
                    re.MULTILINE),
         r'\1\2\3 = \4Py_\6NewRef(\5);'),

        # "Py_INCREF(x); PyObject *var = x;" => "PyObject *var = Py_NewRef(x);"
        # The two statements must have the same indentation, otherwise the
        # regex does not match.
        (re.compile(fr'({INDENTATION_REGEX})'
                      # "Py_INCREF(var);"
                    + fr'Py_(X?)INCREF\(({EXPR_REGEX})\);'
                    + same_indentation(r'\1')
                      # "type* var = expr;"
                    + assign_regex_str(fr'({TYPE_PTR_REGEX} *{EXPR_REGEX})',
                                       fr'({OPT_CAST_REGEX})\3'),
                    re.MULTILINE),
         r'\1\4 = \5Py_\2NewRef(\3);'),
    )
    # Need Py_NewRef(): new in Python 3.10
    NEED_PYTHONCAPI_COMPAT = (MIN_PYTHON < (3, 10))


class Py_CLEAR(Operation):
    NAME = "Py_CLEAR"
    REPLACE = (
        # "Py_XDECREF(x); x = NULL;" => "Py_CLEAR(x)";
        # The two statements must have the same indentation, otherwise the
        # regex does not match.
        (re.compile(fr'({INDENTATION_REGEX})'
                    + fr'Py_XDECREF\(({EXPR_REGEX})\) *;'
                    + same_indentation(r'\1')
                    + assign_regex_str(r'\2', r'NULL'),
                    re.MULTILINE),
         r'\1Py_CLEAR(\2);'),

        # "Py_XDECREF(x); x = NULL;" => "Py_CLEAR(x)";
        (re.compile(fr'Py_XDECREF\(({EXPR_REGEX})\) *;'
                    + fr'{SPACE_REGEX}*'
                    + assign_regex_str(r'\1', r'NULL')),
         r'Py_CLEAR(\1);'),
    )


SETREF_VALUE = fr'{OPT_CAST_REGEX}(?:{EXPR_REGEX}|Py_X?NewRef\({EXPR_REGEX}\))'


class Py_SETREF(Operation):
    NAME = "Py_SETREF"
    REPLACE = (
        # "Py_INCREF(y); Py_CLEAR(x); x = y;" => "Py_XSETREF(x, y)";
        # Statements must have the same indentation, otherwise the regex does
        # not match.
        (re.compile(fr'({INDENTATION_REGEX})'
                    + fr'Py_(X?)INCREF\(({EXPR_REGEX})\) *;'
                    + same_indentation(r'\1')
                    + fr'Py_CLEAR\(({EXPR_REGEX})\) *;'
                    + same_indentation(r'\1')
                    + assign_regex_str(r'\4', r'\3'),
                    re.MULTILINE),
         r'\1Py_XSETREF(\4, Py_\2NewRef(\3));'),

        # "Py_CLEAR(x); x = y;" => "Py_XSETREF(x, y)";
        # Statements must have the same indentation, otherwise the regex does
        # not match.
        (re.compile(fr'({INDENTATION_REGEX})'
                    + fr'Py_CLEAR\(({EXPR_REGEX})\) *;'
                    + same_indentation(r'\1')
                    + assign_regex_str(r'\2',
                                       fr'({SETREF_VALUE})'),
                    re.MULTILINE),
         r'\1Py_XSETREF(\2, \3);'),

        # "Py_INCREF(y); Py_DECREF(x); x = y;" => "Py_SETREF(x, y)";
        # Statements must have the same indentation, otherwise the regex does
        # not match.
        (re.compile(fr'({INDENTATION_REGEX})'
                    + fr'Py_(X?)INCREF\(({EXPR_REGEX})\) *;'
                    + same_indentation(r'\1')
                    + fr'Py_(X?)DECREF\(({EXPR_REGEX})\) *;'
                    + same_indentation(r'\1')
                    + assign_regex_str(r'\5', r'\3'),
                    re.MULTILINE),
         r'\1Py_\4SETREF(\5, Py_\2NewRef(\3));'),

        # "Py_DECREF(x); x = y;" => "Py_SETREF(x, y)";
        # "Py_DECREF(x); x = Py_NewRef(y);" => "Py_SETREF(x, Py_NewRef(y))";
        # Statements must have the same indentation, otherwise the regex does
        # not match.
        (re.compile(fr'({INDENTATION_REGEX})'
                    + fr'Py_(X?)DECREF\(({EXPR_REGEX})\) *;'
                    + same_indentation(r'\1')
                    + assign_regex_str(r'\3',
                                       fr'({SETREF_VALUE})'),
                    re.MULTILINE),
         r'\1Py_\2SETREF(\3, \4);'),

        # "old = var; var = new; Py_DECREF(old);" => "Py_SETREF(var, new);"
        # "PyObject *old = var; var = new; Py_DECREF(old);" => "Py_SETREF(var, new);"
        # Statements must have the same indentation, otherwise the regex does
        # not match.
        (re.compile(fr'({INDENTATION_REGEX})'
                    + fr'(?:{ID_REGEX} *\* *)?({ID_REGEX}) *= *{OPT_CAST_REGEX}({EXPR_REGEX}) *;'
                    + same_indentation(r'\1')
                    + assign_regex_str(r'\3',
                                       fr'({SETREF_VALUE})')
                    + same_indentation(r'\1')
                    + fr'Py_(X?)DECREF\(\2\) *;',
                    re.MULTILINE),
         r'\1Py_\5SETREF(\3, \4);'),
    )
    # Need Py_NewRef(): new in Python 3.5
    NEED_PYTHONCAPI_COMPAT = (MIN_PYTHON < (3, 5))


class Py_Is(Operation):
    NAME = "Py_Is"

    def replace2(regs):
        x = regs.group(1)
        y = regs.group(2)
        if y == 'NULL':
            return regs.group(0)
        return f'{x} = _Py_StealRef({y});'

    REPLACE = []
    expr = fr'({EXPR_REGEX})'
    for name in ('None', 'True', 'False'):
        REPLACE.extend((
            (re.compile(fr'{expr} == Py_{name}\b'),
             fr'Py_Is{name}(\1)'),
            (re.compile(fr'{expr} != Py_{name}\b'),
             fr'!Py_Is{name}(\1)'),
        ))

    # Need Py_IsNone(), Py_IsTrue(), Py_IsFalse(): new in Python 3.10
    NEED_PYTHONCAPI_COMPAT = (MIN_PYTHON < (3, 10))


OPERATIONS = (
    Py_SET_TYPE,
    Py_SET_SIZE,
    Py_SET_REFCNT,
    # Py_SET_xxx must be run before Py_xxx
    Py_TYPE,
    Py_SIZE,
    Py_REFCNT,

    Py_Is,

    PyObject_NEW,
    PyMem_MALLOC,
    PyObject_MALLOC,

    PyFrame_GetBack,
    PyFrame_GetCode,

    PyThreadState_GetInterpreter,
    PyThreadState_GetFrame,

    # Code style: excluded from "all"
    Py_NewRef,
    Py_CLEAR,
    Py_SETREF,
)

EXCLUDE_FROM_ALL = (
    Py_NewRef,
    Py_CLEAR,
    Py_SETREF,
)


def all_operations():
    return set(operation_class.NAME for operation_class in OPERATIONS
               if operation_class not in EXCLUDE_FROM_ALL)


class Patcher:
    def __init__(self, args=None):
        self.exitcode = 0
        self.pythoncapi_compat_added = 0
        self.want_pythoncapi_compat = False
        self.operations = None
        self.applied_operations = set()

        # Set temporarily by patch()
        self._has_pythoncapi_compat = None
        self._applied_operations = None

        self._parse_options(args)

    def log(self, msg=''):
        print(msg, file=sys.stderr, flush=True)

    def warning(self, msg):
        self.log(f"WARNING: {msg}")

    def _get_operations(self, parser):
        args_names = self.args.operations.split(',')

        wanted = set()
        for name in args_names:
            name = name.strip()
            if not name:
                continue

            if name == "all":
                wanted |= all_operations()
            elif name.startswith("-"):
                name = name[1:]
                wanted.discard(name)
            else:
                wanted.add(name)

        operations = []
        for operation_class in OPERATIONS:
            name = operation_class.NAME
            if name not in wanted:
                continue
            wanted.discard(name)
            operation = operation_class(self)
            operations.append(operation)

        if wanted:
            print(f"invalid operations: {','.join(wanted)}")
            print()
            self.usage(parser)
            sys.exit(1)

        return operations

    def add_line(self, content, line):
        # Use the first matching newline
        match = re.search(r'(?:\r\n|\n|\r)', content)
        newline = match.group(0) if match else '\n'

        line = line + newline
        # FIXME: tolerate trailing spaces
        if line not in content:
            # FIXME: add macro after the first header comment
            # FIXME: add macro after includes
            # FIXME: add macro after: #define PY_SSIZE_T_CLEAN
            return line + newline + content
        else:
            return content

    def add_pythoncapi_compat(self, content):
        if self._has_pythoncapi_compat:
            return content
        content = self.add_line(content, INCLUDE_PYTHONCAPI_COMPAT)
        self._has_pythoncapi_compat = True
        self.pythoncapi_compat_added += 1
        return content

    def _patch(self, content):
        try:
            has = (self.args.no_compat
                   or INCLUDE_PYTHONCAPI_COMPAT in content
                   or INCLUDE_PYTHONCAPI_COMPAT2 in content)
            self._has_pythoncapi_compat = has
            self._applied_operations = []
            for operation in self.operations:
                new_content = operation.patch(content)
                if new_content != content:
                    self._applied_operations.append(operation.NAME)
                content = new_content
            applied_operations = self._applied_operations
        finally:
            self._has_pythoncapi_compat = None
            self._applied_operations = None
        return (content, applied_operations)

    def patch(self, content):
        return self._patch(content)[0]

    def patch_file(self, filename):
        if os.path.basename(filename) == PYTHONCAPI_COMPAT_H:
            self.log(f"Skip {filename}")
            return

        encoding = "utf-8"
        errors = "surrogateescape"

        with open(filename, encoding=encoding, errors=errors, newline="") as fp:
            old_contents = fp.read()

        new_contents, operations = self._patch(old_contents)

        if self.args.to_stdout:
            print(new_contents, end="")
            return (new_contents != old_contents)

        # Don't rewrite if the filename for in-place replacement,
        # to avoid changing the file modification time.
        if new_contents == old_contents:
            return False

        if not self.args.no_backup:
            old_filename = filename + ".old"
            # If old_filename already exists, replace it
            os.replace(filename, old_filename)

        with open(filename, "w", encoding=encoding, errors=errors, newline="") as fp:
            fp.write(new_contents)

        self.applied_operations |= set(operations)
        operations = ', '.join(operations)
        self.log(f"Patched file: {filename} ({operations})")
        return True

    def _walk_dir(self, path):
        empty = True

        for dirpath, dirnames, filenames in os.walk(path):
            # Don't walk into .tox
            for ignore_name in IGNORE_DIRS:
                try:
                    dirnames.remove(ignore_name)
                except ValueError:
                    pass
            for filename in filenames:
                if is_c_filename(filename):
                    yield os.path.join(dirpath, filename)
                    empty = False

        if empty:
            self.warning(f"Directory {path} doesn't contain any C file")
            self.exitcode = 1

    def walk(self, paths):
        for path in paths:
            if os.path.isdir(path):
                for filename in self._walk_dir(path):
                    yield filename
            elif os.path.exists(path):
                yield path
            else:
                self.warning(f"Path {path} does not exist")
                self.exitcode = 1

    def get_latest_header(self, base_dir):
        target = os.path.join(base_dir, PYTHONCAPI_COMPAT_H)
        self.log(f"Download the file from {PYTHONCAPI_COMPAT_URL} to {target}.")
        urllib.request.urlretrieve(PYTHONCAPI_COMPAT_URL, target)

    @staticmethod
    def usage(parser):
        parser.print_help()
        print()
        print("Operations:")
        print()
        for operation in sorted(OPERATIONS,
                                key=lambda operation: operation.NAME.lower()):
            print(f"- {operation.NAME}")
        print()
        print("If a directory is passed, search for .c and .h files "
              "in subdirectories.")

    def _parse_dir_path(self, path):
        if os.path.isdir(path):
            return path
        else:
            raise argparse.ArgumentTypeError(f"{path} is not a valid path")

    def _parse_options(self, args):
        parser = argparse.ArgumentParser(
            description="Upgrade C extension modules to newer Python C API")
        parser.add_argument(
            '-o', '--operations', action="store",
            default="all",
            help='Space separated list of operation names to apply')
        parser.add_argument(
            '-q', '--quiet', action="store_true",
            help='Quiet mode')
        parser.add_argument(
            '-c', '--to-stdout', action="store_true",
            help='Write output into stdout instead of modifying files '
                 'in-place (imply quiet mode)')
        parser.add_argument(
            '-B', '--no-backup', action="store_true",
            help="Don't create .old backup files")
        parser.add_argument(
            '-C', '--no-compat', action="store_true",
            help=f"Don't add: {INCLUDE_PYTHONCAPI_COMPAT}")
        parser.add_argument(
            '-d', '--download', metavar='PATH',
            help=f'Download latest pythoncapi_compat.h file to designated PATH',
            type=self._parse_dir_path)
        parser.add_argument(
            metavar='file_or_directory', dest="paths", nargs='*')

        args = parser.parse_args(args)
        if not args.paths and not args.download:
            self.usage(parser)
            sys.exit(1)

        if args.to_stdout:
            args.quiet = True

        self.args = args
        self.operations = self._get_operations(parser)

    def main(self):
        if self.args.paths:
            for filename in self.walk(self.args.paths):
                self.patch_file(filename)

        if self.applied_operations:
            nops = len(self.applied_operations)
            ops = ', '.join(sorted(self.applied_operations))
            self.log()
            self.log(f"Applied operations ({nops}): {ops}")

        if self.args.download:
            path = self.args.download
            self.get_latest_header(path)

        if self.pythoncapi_compat_added and not self.args.quiet:
            self.log()
            self.log(f"{INCLUDE_PYTHONCAPI_COMPAT} added: you may have "
                     f"to copy {PYTHONCAPI_COMPAT_H} to your project")
            self.log("Run 'python upgrade_pythoncapi.py --download <target_path>'")

        sys.exit(self.exitcode)


if __name__ == "__main__":
    Patcher().main()
