#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lint_ports.py -- static structural auditor for the RTL under user_source/hdl_source.

WHY
---
Neither TD nor Icarus treats a silently disconnected net as an error.  The worst
bug of 2026-09 in this project was exactly that class: a wire driven by a
submodule output that nothing ever reads (``sc_fd`` in top_tf_hdmi_audio.v), and
submodule outputs left open at the instantiation site (the two ``full_flag``
FIFO pins in SD/frame_read_write.v).  TD additionally fills the build log with
``HDL-7225 CRITICAL-WARNING: '<name>' is already implicitly declared`` -- implicit
nets are the mechanism that turns a port-name typo into a dangling wire instead
of an error.  This script makes all of that machine checkable.

CATEGORIES (every hit carries file:line)
  1 unconnected_out   submodule OUTPUT that reaches nothing
                        EMPTY  ".port( )"          explicitly left open
                        OMIT   output never listed at all
                        DEAD   ".port(w)" where w is never read anywhere
                               (DEAD == the sc_fd class, EMPTY == the full_flag class)
  2 unconnected_in    submodule INPUT/INOUT left open or tied to a constant
  3 width             formal port width vs. width of the connected expression
  4 bad_port          port name in an instantiation that is not on the module
                      definition (typo -> generator of implicit nets)
  5 implicit          nets used before they exist in module scope
                        NEVER_DECLARED     no declaration anywhere (TD HDL-1007)
                        DECLARE_AFTER_USE  declared later, so the first use already
                                           created a 1-bit implicit net
                                           (TD HDL-7225 / HDL-5373)
  6 usage             DEAD_WRITE     wire/reg written but never read (dead)
                        NEVER_WRITE    wire read but never driven (stuck-at-Z)
                        PORT_UNDRIVEN  module output with no driver inside
                        PORT_UNUSED    module input never read inside

EXIT STATUS
  0 clean, 1 category 1 or category 4 present (CI gate), 3 known-bug regression
  failed, 2 internal error.  Output is ASCII only (this shell mangles non-ASCII).

USAGE
  python -X utf8 tools/lint_ports.py
  python -X utf8 tools/lint_ports.py --root C:/td_batch/lab_pro --all
  python -X utf8 tools/lint_ports.py --json
  python -X utf8 tools/lint_ports.py --check-known    # regression self test
  python -X utf8 tools/lint_ports.py --td-compare "td_project10/*.logw"
"""

from __future__ import annotations

import argparse
import bisect
import glob
import io
import json
import os
import re
import sys
from collections import OrderedDict

# --------------------------------------------------------------------------- #
# configuration
# --------------------------------------------------------------------------- #

DEFAULT_SRC = os.path.join("user_source", "hdl_source")
SKIP_SUFFIX = "_sim.v"                          # vendor simulation models
VENDOR_HINTS = ("hdl_source/IP/", "/include/", "hdmi1.4b_transmitter_core",
                ".enc.v")

# Known-real 2026-09 bugs: the auditor MUST report all of these.
KNOWN_TARGETS = [
    ("unconnected_out", "DEAD", "sc_fd", "top_tf_hdmi_audio.v", 718),
    ("unconnected_out", "EMPTY", "full_flag", "frame_read_write.v", 101),
    ("unconnected_out", "EMPTY", "full_flag", "frame_read_write.v", 153),
]

DECL_KEYWORDS = ["input", "output", "inout", "wire", "reg", "integer", "real",
                 "realtime", "time", "genvar", "bit", "byte", "logic",
                 "supply0", "supply1", "tri", "triand", "trior", "trireg",
                 "tri0", "tri1", "wand", "wor", "event", "localparam",
                 "parameter", "specparam"]
PARAM_KEYWORDS = ("localparam", "parameter", "specparam")
PORT_DIRS = ("input", "output", "inout")

KEYWORDS = set("""
abspos acceptsof after alias and assert assign assume attribute before begin
bind buf bufif0 bufif1 byte case casex casez cell cmos config const continue
dead default defparam design disable edge else end endcase endconfig endfunction
endgenerate endinterface endmodule endprimitive endprogram endproperty
endsequence endsampleddesigntoendcase specify endtable endtask enum event export
extends extern final first_for for force foreach forever fork function generate
highz0 highz1 if ifnone initial inout input inslib instance integer interface
join join_any join_none large liblist library localparam logic macromodule matches
modport module nand new nandedge nested nor not notify null off on option or
output overrided package parameter pmos posedge primitive program property pull0
pull1 pure rand rcassign rclocking real real-time realtime ref register reject
release restrict rnassign ror rntransition rposedgenote sampled sdefault seq
sequence signed small specparam strong0 strong1 struct supdel sup0 sup1 table
tag task this time timeprecision timeunit trans tri tri0 tri1 triand trior
trireg typedef union unique unsigned until var vectored virtual void wait wand
weak0 weak1 while with within wor xnor xor
""".split() + DECL_KEYWORDS + [
    "always", "always_comb", "always_ff", "always_latch", "automatic", "bit",
    "byte", "casez", "genvar", "identifier", "interface", "input", "localreal",
    "output", "package", "rand", "real", "realtime", "scalared", "signed",
    "specparam", "string", "struct", "supply0", "supply1", "triand", "trior",
    "trireg", "union", "unsigned", "wand", "wor", "xnor", "deassert", "edge",
    "event", "export", "extends", "import", "label", "local", "macro",
    "macromodule", "negedge", "posedge", "soft", "timescale", "undef",
    "undefine", "wait", "accept_on", "checker", "endsampleddesigntoend",
]) - {"wait"}
EXTRA_SKIP_WORDS = set("""
begin end else module macromodule endmodule function task endfunction endtask
generate endgenerate case casex casez endcase for while repeat forever initial
always always_ff always_comb always_latch assign deassign force release disable
signed unsigned posedge negedge edge or and nand nor xor xnot buf bufif0 bufif1
notif0 notif1 pulldown pullup tran rtran specparam table endtable input output
inout wire reg integer real realtime time genvar logic bit byte event localparam
parameter automatic import export wait join fork disable return with inside
default rand volatile const static typedef class interface modport
""".split())

IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_$]*")
# a declarator list never contains these: they mean the statement ran away
STATEMENT_STOP = re.compile(r"\b(?:begin|end|if|else|case|casex|casez|for|while|"
                            r"repeat|forever|always|initial|wait|disable)\b")
SIZED_RE = re.compile(r"^(?P<bits>\d+)?'(?P<sign>[sS])?"
                      r"(?P<base>[bBoOdDhH])(?P<digits>[0-9a-fA-F_xXzZ?]+)$")
DIRECTIVE_RE = re.compile(r"^\s*`(\w+)\s*(.*)$")

CATS = ("unconnected_out", "unconnected_in", "width", "bad_port", "implicit",
        "usage")
SEV_RANK = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

def ascii_only(text):
    return "".join(ch if (32 <= ord(ch) < 128) else (" " if ch == "\t" else "?")
                   for ch in text)


def find_matching(text, start, opener="(", closer=")"):
    """Index of the bracket matching text[start] == opener, else -1."""
    depth, i, n = 0, start, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            j = text.find('"', i + 1)
            i = n if j < 0 else j + 1
            continue
        if ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def split_top(text, sep=","):
    """Split on `sep` outside brackets/strings -> [(offset, piece)]."""
    parts, i, n, start, depth = [], 0, len(text), 0, 0
    while i < n:
        ch = text[i]
        if ch == '"':
            j = text.find('"', i + 1)
            i = n if j < 0 else j + 1
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == sep and depth == 0:
            parts.append((start, text[start:i]))
            start = i + 1
        i += 1
    parts.append((start, text[start:]))
    return parts


def vlog_number(tok):
    m = SIZED_RE.match(tok.strip())
    if not m:
        return None
    digits = m.group("digits").replace("_", "")
    if any(c in "xXzZ?" for c in digits):
        return None
    radix = {"b": 2, "o": 8, "d": 10, "h": 16}[m.group("base").lower()]
    try:
        return int(digits, radix) if digits else 0
    except ValueError:
        return None


_NEWLINE_INDEX = {}            # id(text) -> (text, [offsets])


def line_of(line_map, text, off):
    """(path, lineno) of an offset, using a cached newline index (offsets O(log n))."""
    nl = _NEWLINE_INDEX.get(id(text))
    if nl is None or nl[0] is not text:
        nl = (text, [m.start() for m in re.finditer("\n", text)])
        _NEWLINE_INDEX[id(text)] = nl
    idx = bisect.bisect_right(nl[1], off)
    if not line_map:
        return ("?", 0)
    idx = min(max(0, idx), len(line_map) - 1)
    return line_map[idx]


# --------------------------------------------------------------------------- #
# constant expression evaluation
# --------------------------------------------------------------------------- #

class EvalError(Exception):
    pass


class ConstEval(object):
    """Verilog constant expression -> int.  Anything unknown raises EvalError."""

    PREC = [["||"], ["&&"], ["|"], ["^", "~^", "^~"], ["&"], ["==", "!="],
            ["<", "<=", ">", ">="], ["<<", ">>", "<<<", ">>>"], ["+", "-"],
            ["*", "/"], ["%"], ["**"]]

    def __init__(self, env):
        self.env = env or {}

    def evaluate(self, text):
        self.toks = self._tokenize(text)
        self.i = 0
        if not self.toks:
            raise EvalError("empty")
        val = self._ternary()
        if self.i != len(self.toks):
            raise EvalError("trailing tokens")
        if not isinstance(val, int):
            raise EvalError("not an int")
        return val

    def _tokenize(self, text):
        toks, i, n = [], 0, len(text)
        ops3 = ("<<<", ">>>")
        ops2 = ("==", "!=", "<=", ">=", "&&", "||", "~^", "^~", "<<", ">>", "**")
        ops1 = "+-*/%()[]?:~!&|^<>"
        while i < n:
            ch = text[i]
            if ch.isspace():
                i += 1
                continue
            if ch == "\\" and i + 1 < n:
                j = i + 1
                while j < n and not text[j].isspace():
                    j += 1
                toks.append(text[i + 1:j])
                i = j
                continue
            m = re.match(r"\$\w+", text[i:])
            if m:
                toks.append(m.group(0))
                i += m.end()
                continue
            m = re.match(r"\d*'[sSbBoOdDhH][0-9a-fA-FxXzZ_?]+", text[i:])
            if m:
                toks.append(m.group(0))
                i += m.end()
                continue
            m = re.match(r"\d+", text[i:])
            if m:
                toks.append(m.group(0))
                i += m.end()
                continue
            m = IDENT_RE.match(text, i)
            if m:
                toks.append(m.group(0))
                i = m.end()
                continue
            if text[i:i + 3] in ops3:
                toks.append(text[i:i + 3])
                i += 3
                continue
            if text[i:i + 2] in ops2:
                toks.append(text[i:i + 2])
                i += 2
                continue
            if ch in ops1:
                toks.append(ch)
                i += 1
                continue
            raise EvalError("bad char %r" % ch)
        return toks

    def _peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else None

    def _eat(self, tok):
        if self._peek() == tok:
            self.i += 1
            return True
        return False

    def _ternary(self):
        cond = self._bin(0)
        if self._eat("?"):
            a = self._ternary()
            if not self._eat(":"):
                raise EvalError("missing :")
            return a if cond else self._ternary()
        return cond

    def _bin(self, prec):
        if prec >= len(self.PREC):
            return self._unary()
        val = self._bin(prec + 1)
        while self._peek() in self.PREC[prec]:
            op = self.toks[self.i]
            self.i += 1
            val = self._op(op, val, self._bin(prec + 1))
        return val

    def _unary(self):
        tok = self._peek()
        if tok in ("-", "+", "!", "~", "&", "|", "^"):
            self.i += 1
            v = self._unary()
            if tok == "-":
                return -v
            if tok in ("!", "~"):
                return (~v) if tok == "~" else int(v == 0)
            return int(v != 0)
        return self._atom()

    def _atom(self):
        tok = self._peek()
        if tok is None:
            raise EvalError("unexpected end")
        if tok == "(":
            self.i += 1
            v = self._ternary()
            if not self._eat(")"):
                raise EvalError("missing )")
            return v
        self.i += 1
        if tok.startswith("$"):
            if tok == "$clog2":
                if not self._eat("("):
                    raise EvalError("$clog2(")
                arg = self._ternary()
                if not self._eat(")"):
                    raise EvalError("$clog2)")
                v, c = 1, 0
                while v < arg:
                    v <<= 1
                    c += 1
                return c
            raise EvalError("system fn " + tok)
        if SIZED_RE.match(tok):
            v = vlog_number(tok)
            if v is None:
                raise EvalError("x/z literal")
            return v
        if re.match(r"^\d+$", tok):
            return int(tok)
        if tok in self.env and isinstance(self.env[tok], int):
            return self.env[tok]
        raise EvalError("unknown " + tok)

    @staticmethod
    def _op(op, a, b):
        try:
            if op == "+":
                return a + b
            if op == "-":
                return a - b
            if op == "*":
                return a * b
            if op == "/":
                return a // b if b else 0
            if op == "%":
                return a % b if b else 0
            if op == "**":
                return a ** b if b >= 0 else 0
            if op in ("<<", "<<<"):
                return a << b
            if op in (">>", ">>>"):
                return a >> b
            if op == "<":
                return int(a < b)
            if op == ">":
                return int(a > b)
            if op == "<=":
                return int(a <= b)
            if op == ">=":
                return int(a >= b)
            if op == "==":
                return int(a == b)
            if op == "!=":
                return int(a != b)
            if op == "&&":
                return int(bool(a) and bool(b))
            if op == "||":
                return int(bool(a) or bool(b))
            if op == "&":
                return a & b
            if op == "|":
                return a | b
            if op == "^":
                return a ^ b
            if op in ("~^", "^~"):
                return ~(a ^ b)
        except (ValueError, TypeError, OverflowError):
            raise EvalError("apply " + op)
        raise EvalError("op " + op)


def const_value(text, env):
    if text is None:
        return None
    text = text.strip()
    if not text:
        return None
    try:
        return ConstEval(env).evaluate(text)
    except Exception:
        return None


def range_width(range_text, env):
    if range_text is None:
        return 1
    parts = split_top(range_text, ":")
    if len(parts) != 2:
        return None
    msb = const_value(parts[0][1], env)
    lsb = const_value(parts[1][1], env)
    if msb is None or lsb is None:
        return None
    return abs(msb - lsb) + 1


# --------------------------------------------------------------------------- #
# preprocessor
# --------------------------------------------------------------------------- #

class Prepro(object):
    """Blank comments, expand `include, evaluate `ifdef, expand `define.

    Emits logical lines as (text, path, lineno) so every reported position maps
    back to a real source line, including inside included fragments.
    """

    def __init__(self, base=None):
        self.defines = {}
        self.notes = []
        self.cache = {}
        self.base = os.path.abspath(base or os.getcwd())
        self._idx = None
        self.pragmas = {}          # disp path -> set of `default_nettype etc.

    def disp(self, path):
        try:
            return os.path.relpath(os.path.abspath(path),
                                   self.base).replace("\\", "/")
        except ValueError:
            return os.path.abspath(path).replace("\\", "/")

    @staticmethod
    def blank_comments(raw):
        """Blank comment characters (strings are left intact for `include)."""
        out = list(raw)
        i, n, state = 0, len(raw), None
        while i < n:
            ch = raw[i]
            nx = raw[i + 1] if i + 1 < n else ""
            if state == "line":
                if ch == "\n":
                    state = None
                else:
                    out[i] = " "
                i += 1
                continue
            if state == "block":
                if ch == "*" and nx == "/":
                    out[i] = out[i + 1] = " "
                    state = None
                    i += 2
                    continue
                if ch != "\n":
                    out[i] = " "
                i += 1
                continue
            if state == "str":
                if ch == '"':
                    state = None
                i += 1
                continue
            if ch == "/" and nx == "/":
                state = "line"
                out[i] = out[i + 1] = " "
                i += 2
            elif ch == "/" and nx == "*":
                state = "block"
                out[i] = out[i + 1] = " "
                i += 2
            elif ch == '"':
                state = "str"
                i += 1
            else:
                i += 1
        return "".join(out)

    @staticmethod
    def blank_strings(line):
        """Replace string literals with spaces (per line, after directives)."""
        if '"' not in line:
            return line
        out = list(line)
        i, n = 0, len(line)
        while i < n:
            if line[i] == '"':
                j = line.find('"', i + 1)
                j = n - 1 if j < 0 else j
                for x in range(i, j + 1):
                    out[x] = " "
                i = j + 1
                continue
            i += 1
        return "".join(out)

    def lines_of(self, path, disp=None):
        key = os.path.abspath(path)
        if key in self.cache:
            return self.cache[key]
        disp = disp or self.disp(path)
        try:
            with io.open(path, "rb") as fh:
                blob = fh.read()
        except (IOError, OSError) as exc:
            self.notes.append("UNREADABLE %s (%s)" % (disp, type(exc).__name__))
            self.cache[key] = []
            return []
        try:
            raw, enc = blob.decode("utf-8"), "utf-8"
        except UnicodeDecodeError:
            raw, enc = blob.decode("latin-1"), "latin-1"
        if any(ord(c) > 127 for c in raw):
            self.notes.append("non-ASCII text decoded as %s: %s" % (enc, disp))
        raw = self.blank_comments(raw)
        phys = raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        lines = [(t, disp, k + 1) for k, t in enumerate(phys)]
        for m in re.finditer(r"`(default_nettype|resetall)\s*(\w*)", raw):
            self.pragmas.setdefault(disp, set()).add(
                m.group(1) + " " + m.group(2))
        self.cache[key] = lines
        return lines

    def _index(self, roots):
        if self._idx is not None:
            return self._idx
        self._idx = {}
        for root in roots:
            if not os.path.isdir(root):
                continue
            for dirpath, _dn, files in os.walk(root):
                for fn in files:
                    self._idx.setdefault(fn, os.path.join(dirpath, fn))
        return self._idx

    def build_index(self, roots):
        self._idx = None
        self._index(roots)

    def find_include(self, name, cur_dir, roots):
        cands = []
        if cur_dir:
            cands.append(os.path.normpath(os.path.join(self.base, cur_dir, name)))
        for root in roots:
            cands += [os.path.join(root, name), os.path.join(root, "include", name)]
        for c in cands:
            if os.path.isfile(c):
                return c
        hit = self._index(roots).get(os.path.basename(name))
        return hit

    def run(self, path, roots, disp=None):
        return self._expand(path, disp or self.disp(path), roots,
                            frozenset([os.path.abspath(path)]))

    def _expand(self, path, disp, roots, seen):
        lines = self.lines_of(path, disp)
        out, stack, i = [], [], 0

        def active():
            return all(fr[0] for fr in stack)

        while i < len(lines):
            text, fpath, fline = lines[i]
            i += 1
            m = DIRECTIVE_RE.match(text)
            if not m:
                out.append((text if active() else "", fpath, fline))
                continue
            d, rest = m.group(1), m.group(2).strip()
            if d in ("ifdef", "ifndef", "elsif", "else", "endif"):
                if d in ("ifdef", "ifndef"):
                    nm = rest.split()[0] if rest.split() else ""
                    here = (nm in self.defines) if d == "ifdef" \
                        else (nm not in self.defines)
                    ok = active() and here
                    stack.append([ok, ok])
                elif d == "elsif" and stack:
                    parent = all(fr[0] for fr in stack[:-1])
                    nm = rest.split()[0] if rest.split() else ""
                    ok = parent and not stack[-1][1] and nm in self.defines
                    stack[-1] = [ok, stack[-1][1] or ok]
                elif d == "else" and stack:
                    parent = all(fr[0] for fr in stack[:-1])
                    ok = parent and not stack[-1][1]
                    stack[-1] = [ok, stack[-1][1] or ok]
                elif d == "endif" and stack:
                    stack.pop()
                out.append(("", fpath, fline))
                continue
            if not active():
                out.append(("", fpath, fline))
                continue
            if d == "define":
                mm = re.match(r"([A-Za-z_]\w*)\s*(.*)$", rest, re.S)
                if mm:
                    self.defines[mm.group(1)] = mm.group(2).strip()
                out.append(("", fpath, fline))
                continue
            if d == "undef":
                if rest.split():
                    self.defines.pop(rest.split()[0], None)
                out.append(("", fpath, fline))
                continue
            if d == "include":
                name = rest.strip().strip('"').strip("<>")
                inc = self.find_include(name, os.path.dirname(fpath), roots)
                if inc is None:
                    self.notes.append('unresolved include "%s" at %s:%d'
                                      % (name, fpath, fline))
                elif os.path.abspath(inc) not in seen:
                    out.extend(self._expand(inc, self.disp(inc), roots,
                                            seen | {os.path.abspath(inc)}))
                out.append(("", fpath, fline))
                continue
            out.append(("", fpath, fline))       # `timescale and friends
        return [(self._macros(self.blank_strings(t)), f, n) for t, f, n in out]

    def _macros(self, text):
        if "`" not in text:
            return text
        for _ in range(4):
            new = re.sub(r"`([A-Za-z_]\w*)",
                         lambda mm: self.defines.get(mm.group(1), mm.group(0)),
                         text)
            if new == text:
                break
            text = new
        return text.replace("`", " ")


# --------------------------------------------------------------------------- #
# model
# --------------------------------------------------------------------------- #

class Port(object):
    __slots__ = ("name", "dir", "range", "kind", "off")

    def __init__(self, name, direction, range_text, kind, off):
        self.name, self.dir, self.range = name, direction, range_text
        self.kind, self.off = kind, off


class Decl(object):
    __slots__ = ("name", "kind", "range", "off", "value")

    def __init__(self, name, kind, range_text, off, value=None):
        self.name, self.kind, self.range, self.off = name, kind, range_text, off
        self.value = value


class Conn(object):
    __slots__ = ("port", "port_off", "expr", "expr_off")

    def __init__(self, port, port_off, expr, expr_off):
        self.port, self.port_off = port, port_off
        self.expr, self.expr_off = expr, expr_off


class Instance(object):
    __slots__ = ("mname", "iname", "off", "end", "module_off", "iname_off",
                 "conns", "params")

    def __init__(self):
        self.mname = self.iname = ""
        self.off = self.end = self.module_off = self.iname_off = 0
        self.conns, self.params = [], []


class Module(object):
    def __init__(self, uid, name, path, text, line_map):
        self.uid = uid
        self.name = name
        self.path = path
        self.text = text
        self.line_map = line_map
        self.ports = OrderedDict()
        self.port_names = []
        self.decls = OrderedDict()
        self.params = OrderedDict()
        self.instances = []
        self.skip_off = set()
        self.func_names = set()
        self.init_driven = set()              # wire x = ...;  (decl drives it)
        self.occ = {}                     # name -> [(off, is_write)]
        self.net_w = {}
        self.env = {}
        self.body_start = 0

    def at(self, off):
        return line_of(self.line_map, self.text, off)

    def is_vendor(self):
        p = self.path.replace("\\", "/")
        return any(h in p for h in VENDOR_HINTS)

    def line(self, off):
        return self.at(off)[1]


# --------------------------------------------------------------------------- #
# parser
# --------------------------------------------------------------------------- #

def declarator_names(chunk, base_off, want_range=True):
    """Names declared by a declarator list, plus the first range text.

    Bracket contents and initialiser text are masked out so only the declared
    identifiers survive; absolute offsets are preserved.
    """
    n = len(chunk)
    mask = [False] * n
    range_text = None
    segs, depth, i, seg_start = [], 0, 0, 0
    while i < n:
        ch = chunk[i]
        if ch == '"':
            j = chunk.find('"', i + 1)
            i = (n if j < 0 else j + 1)
            continue
        if ch in "([{":
            depth += 1
            if ch == "[" and depth == 1:
                j = find_matching(chunk, i, "[", "]")
                if j > 0 and range_text is None and want_range:
                    range_text = chunk[i + 1:j]
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            segs.append((seg_start, i))
            seg_start = i + 1
        i += 1
    segs.append((seg_start, n))
    for (s, e) in segs:
        j = s
        while j < e:
            ch = chunk[j]
            if ch in "([{":
                closer = {"[": "]", "(": ")", "{": "}"}[ch]
                k = find_matching(chunk, j, ch, closer)
                k = e - 1 if (k < 0 or k >= e) else k
                for x in range(j, k + 1):
                    mask[x] = True
                j = k + 1
                continue
            if ch == "=" and not (j + 1 < e and chunk[j + 1] in "=>"):
                for x in range(j, e):
                    mask[x] = True
                break
            j += 1
    clean = "".join(" " if mask[x] else chunk[x] for x in range(n))
    names = []
    for mm, off in ident_tokens(clean):
        nm = mm.group(0)
        if nm in KEYWORDS or nm in DECL_KEYWORDS:
            continue
        names.append((nm, base_off + off))
    return range_text, names


def ident_tokens(text, start=0):
    """Identifier tokens, rejecting number tails (25_175_000), 'b1 in 1'b1,
    and hierarchical members (u_inst.sig)."""
    for mm in IDENT_RE.finditer(text, start):
        off = mm.start()
        prev = text[off - 1] if off else ""
        if prev.isdigit() or prev == "'" or prev == ".":
            continue
        yield mm, off


class Parser(object):
    def __init__(self, pp):
        self.pp = pp

    def modules_in_file(self, path, lines, seq):
        text = "\n".join(t for t, _f, _n in lines)
        mods = []
        starts = [m.start() for m in
                  re.finditer(r"(?m)^[ \t]*(?:module|macromodule)[ \t]+(\w+)", text)]
        groups = list(re.finditer(r"(?m)^[ \t]*(?:module|macromodule)[ \t]+(\w+)",
                                  text))
        for idx, mm in enumerate(groups):
            endm = re.compile(r"(?m)^[ \t]*endmodule\b").search(text, mm.end())
            nxt = starts[idx + 1] if idx + 1 < len(starts) else len(text)
            truncated = False
            if endm and endm.start() < nxt:
                seg = text[mm.start():endm.end()]
            elif not endm:
                # `pragma protect encrypted body (TD vendor IP): the header is
                # readable, the module body is not.  Parse the port map only.
                seg = text[mm.start():nxt]
                truncated = True
            else:
                seg = text[mm.start():nxt]
                truncated = True
            pre = text.count("\n", 0, mm.start())
            sub_map = lines[pre:pre + seg.count("\n") + 1] or lines[:1]
            mod = Module("%s::%s#%d" % (path, mm.group(1), seq + len(mods)),
                         mm.group(1), path, seg,
                         [(p, n) for _t, p, n in sub_map])
            mod.truncated = truncated
            if truncated:
                mod.no_body = True
            try:
                self.parse_module(mod)
            except Exception as exc:
                raise RuntimeError("module %s: %s: %s"
                                   % (mm.group(1), type(exc).__name__, exc))
            mods.append(mod)
        return mods

    # -- header ------------------------------------------------------------- #
    def parse_module(self, mod):
        text = mod.text
        mm = re.match(r"(?:module|macromodule)\s+(\w+)\s*", text)
        cur = mm.end()
        if cur < len(text) and text[cur] == "#":
            po = text.find("(", cur)
            pc = find_matching(text, po) if po > 0 else -1
            if pc < 0:
                return
            self._parse_params(mod, text[po + 1:pc], po + 1)
            cur = pc + 1
        while cur < len(text) and text[cur].isspace():
            cur += 1
        if cur < len(text) and text[cur] == "(":
            pc = find_matching(text, cur)
            if pc < 0:
                return
            self._parse_ports(mod, text[cur + 1:pc], cur + 1)
            semi = text.find(";", pc)
            mod.body_start = semi + 1 if semi > 0 else pc + 1
        else:
            mod.body_start = cur
        if getattr(mod, "no_body", False):
            return                     # header only (encrypted/pruned body)
        self._parse_body(mod)

    def _parse_params(self, mod, chunk, base):
        for off, part in split_top(chunk, ","):
            cleaned = re.sub(r"\[[^\]]*\]", " ",
                             re.sub(r"\b(parameter|localparam|integer|signed|"
                                    r"unsigned|realtime|time|real)\b", " ", part))
            cleaned = re.sub(r"=.*$", "", cleaned, flags=re.S)
            ids = [x for x in IDENT_RE.findall(cleaned) if x not in KEYWORDS]
            if not ids:
                continue
            name = ids[0]
            value = part.split("=", 1)[1] if "=" in part else None
            value = re.sub(r"\[[^\]]*\]", " ", value) if value else None
            o = base + off + (cleaned.rindex(name) if name in cleaned else 0)
            if name not in mod.params:
                mod.params[name] = Decl(name, "parameter", None, o, value)
            mod.skip_off.add(o)

    def _parse_ports(self, mod, chunk, base):
        items = split_top(chunk, ",")
        ansi = any(re.match(r"\s*(input|output|inout)\b", p) for _o, p in items)
        mod.nonansi = not ansi
        carry = None
        if not ansi:
            for off, part in items:
                cleaned = re.sub(r"\[[^\]]*\]", " ", part)
                for mm, moff in ident_tokens(cleaned):
                    nm = mm.group(0)
                    if nm in KEYWORDS:
                        continue
                    o = base + off + moff
                    mod.skip_off.add(o)
                    if nm not in mod.ports:
                        mod.ports[nm] = Port(nm, None, None, None, o)
                        mod.port_names.append(nm)
            return
        for off, part in items:
            dmm = re.match(r"\s*(input|output|inout)\b", part)
            if dmm:
                direction = dmm.group(1)
                body = part[dmm.end():]
                kind = "reg" if re.search(r"\breg\b", body) else "wire"
                r, names = declarator_names(body, base + off + dmm.end())
                carry = (direction, r, kind)
            else:
                # Verilog-2001 continuation: `input wire [15:0] a, b, c` puts the
                # 2nd..nth names in their own comma item, direction inherited.
                if carry is None:
                    continue
                direction, r, kind = carry
                _junk, names = declarator_names(part, base + off)
            for nm, o in names:
                mod.skip_off.add(o)
                if nm in mod.ports:
                    continue
                mod.ports[nm] = Port(nm, direction, r, kind, o)
                mod.port_names.append(nm)

    # -- body --------------------------------------------------------------- #
    @staticmethod
    def _routine_name(text, i):
        """Skip net/typing tokens to reach the function/task's own name."""
        for _ in range(8):
            while i < len(text) and text[i].isspace():
                i += 1
            if i >= len(text):
                return None, i
            if text[i] == "[":
                j = find_matching(text, i, "[", "]")
                i = (j + 1) if j > 0 else i + 1
                continue
            m = re.match(r"(?:automatic|static|const|randc|rand|unsigned|signed|"
                         r"void|integer|realtime|real|time|reg|wire|logic|bit|"
                         r"byte|string)\b", text[i:])
            if m:
                i += m.end()
                continue
            m = IDENT_RE.match(text, i)
            return (m.group(0), i) if m else (None, i)
        return None, i

    def _routine_regions(self, mod):
        """Register function/task names and their (start, end) text regions."""
        text = mod.text
        regions = []
        for mm in re.finditer(r"\b(function|task)\b", text):
            if mm.start() < mod.body_start:
                continue
            if any(rs <= mm.start() < re_ for rs, re_, _n in regions):
                continue                       # already inside another routine
            endw = re.compile(r"\bend%s\b" % mm.group(1)).search(text, mm.end())
            if not endw:
                continue
            name, name_off = self._routine_name(text, mm.end())
            if name and name not in KEYWORDS and name != mm.group(1):
                mod.func_names.add(name)
                mod.skip_off.add(name_off)
            regions.append((mm.start(), endw.end(), name))
        return regions

    def _parse_body(self, mod):
        text = mod.text
        b0 = mod.body_start
        regions = self._routine_regions(mod)

        def in_routine(off):
            return any(rs <= off < re_ for rs, re_, _n in regions)

        for kw in DECL_KEYWORDS:
            for mm in re.finditer(r"\b%s\b" % re.escape(kw), text):
                if mm.start() < b0:
                    continue
                i, depth, end = mm.end(), 0, -1
                while i < len(text) and i - mm.end() < 700:
                    ch = text[i]
                    if ch in "([{":
                        depth += 1
                    elif ch in ")]}":
                        depth -= 1
                        if depth < 0:
                            break              # left the enclosing construct
                    elif ch.isalpha() and depth == 0 and i > mm.end():
                        if STATEMENT_STOP.match(text, i):
                            break
                    elif ch == ";" and depth == 0:
                        end = i
                        break
                    i += 1
                if end < 0:
                    continue
                chunk = text[mm.end():end]
                if not chunk.strip():
                    continue
                is_param = kw in PARAM_KEYWORDS
                r, names = declarator_names(chunk, mm.end(), want_range=not is_param)
                local = in_routine(mm.start())
                segs = split_top(chunk, ",")

                def has_init(off, nm):
                    """True when this declarator carries an '=' initialiser,
                    i.e. the declaration itself is a driver (wire x = a & b;)."""
                    rel = off - mm.end()
                    for so, sp in segs:
                        if so <= rel < so + len(sp):
                            after = sp[rel - so + len(nm):]
                            return "=" in after
                    return False

                for nm, o in names:
                    mod.skip_off.add(o)
                    if (not is_param) and not local and has_init(o, nm):
                        mod.init_driven.add(nm)
                    if local and not is_param:
                        # task/function argument or local: a declaration, but
                        # emphatically not a module port
                        if nm not in mod.decls and nm not in mod.ports:
                            mod.decls[nm] = Decl(nm, kw + " (local)", r, o)
                        continue
                    if nm in mod.ports:
                        p = mod.ports[nm]
                        if p.dir is None:
                            p.dir = kw if kw in PORT_DIRS else p.dir
                            if r:
                                p.range = r
                            p.kind = p.kind or "wire"
                        continue
                    if nm in mod.params or nm in mod.func_names:
                        continue
                    if is_param:
                        pre, _, val = chunk.partition("=")
                        mod.params[nm] = Decl(nm, kw, None, o,
                                              re.sub(r"\[[^\]]*\]", " ", val)
                                              if val else None)
                    elif kw in PORT_DIRS and getattr(mod, "nonansi", False):
                        mod.ports[nm] = Port(nm, kw, r, "wire", o)
                        mod.port_names.append(nm)
                    else:
                        if nm not in mod.decls:
                            # first declaration wins: the earliest offset is what
                            # matters for declare-after-use detection
                            mod.decls[nm] = Decl(nm, kw, r, o)
        for mm in re.finditer(r"\b(?:begin|end)\s*:\s*(\w+)|(\w+)\s*:\s*(?:begin"
                              r"|case|casex|casez|if|for|while|fork|generate)\b",
                              text):
            mod.skip_off.add(mm.start(1) if mm.group(1) else mm.start(2))
        self._parse_instances(mod)
        self._collect_uses(mod)

    # -- instantiations ----------------------------------------------------- #
    def _stmt_start_ok(self, mod, off):
        """True if this identifier starts a statement (bounded backward scan)."""
        prev = mod.text[max(0, off - 400):off].rstrip()
        if not prev:
            return True
        if re.search(r"[;:{}]\s*$", prev):
            return True
        tail = re.search(r"(\w+)$", prev)
        if not tail:
            return False
        return tail.group(1) in ("begin", "end", "else")

    def _parse_instances(self, mod):
        text = mod.text
        b0 = mod.body_start
        cursor = b0
        for mm in IDENT_RE.finditer(text, b0):
            if mm.start() < cursor:
                continue
            off = mm.start()
            mname = mm.group(0)
            if (mname in KEYWORDS or mname in DECL_KEYWORDS
                    or mname in mod.func_names or mname == mod.name):
                continue
            if not self._stmt_start_ok(mod, off):
                continue
            j = mm.end()
            while j < len(text) and text[j].isspace():
                j += 1
            inst = None
            if j < len(text) and text[j] == "(":
                inst = self._try_conns(mod, mname, None, off, j)
            elif j < len(text) and text[j] == "#":
                po = text.find("(", j)
                pc = find_matching(text, po) if po > 0 else -1
                if pc > 0:
                    k = pc + 1
                    while k < len(text) and text[k].isspace():
                        k += 1
                    m2 = IDENT_RE.match(text, k)
                    if m2 and m2.group(0) not in KEYWORDS:
                        k = m2.end()
                        while k < len(text) and text[k].isspace():
                            k += 1
                        if k < len(text) and text[k] == "(":
                            inst = self._try_conns(mod, mname, m2.group(0), off,
                                                   k, text[po + 1:pc])
            else:
                m2 = IDENT_RE.match(text, j)
                if m2 and m2.group(0) not in KEYWORDS and m2.group(0) not in DECL_KEYWORDS:
                    nm2 = m2.group(0)
                    k = m2.end()
                    while k < len(text) and text[k].isspace():
                        k += 1
                    if k < len(text) and text[k] == "(":
                        inst = self._try_conns(mod, mname, nm2, off, k)
            if inst is None:
                continue
            mod.instances.append(inst)
            cursor = inst.end
            mod.skip_off.add(inst.module_off)
            if inst.iname:
                mod.skip_off.add(inst.iname_off)
            for c in inst.conns:
                mod.skip_off.add(c.port_off)

    def _try_conns(self, mod, mname, iname, off, po, params_text=None):
        text = mod.text
        pc = find_matching(text, po)
        if pc < 0:
            return None
        tail = text[pc + 1:pc + 60].lstrip()
        if not tail.startswith(";"):
            return None
        if iname is None and not text[po + 1:pc].strip():
            return None                     # empty () with no name: not an instance
        inst = Instance()
        inst.mname, inst.iname = mname, iname or ""
        inst.off, inst.end = off, pc + 1
        inst.module_off = off
        inst.iname_off = off
        if iname:
            try:
                inst.iname_off = text.index(iname, off)
            except ValueError:
                inst.iname_off = off
        for so, part in split_top(text[po + 1:pc], ","):
            g = re.match(r"\s*\.\s*(\w+)\s*\((.*)\)\s*$", part, re.S)
            if not g:
                continue
            base = po + 1 + so
            raw_expr = g.group(2)
            lead = len(raw_expr) - len(raw_expr.lstrip())
            inst.conns.append(Conn(g.group(1), base + g.start(1),
                                   raw_expr.strip(), base + g.start(2) + lead))
        if params_text:
            for _so, part in split_top(params_text, ","):
                g = re.match(r"\s*\.\s*(\w+)\s*\((.*)\)\s*$", part, re.S)
                if g:
                    inst.params.append((g.group(1), g.group(2).strip()))
                else:
                    g2 = re.match(r"\s*(\w+)\s*=\s*(.+)$", part, re.S)
                    if g2:
                        inst.params.append((g2.group(1), g2.group(2).strip()))
        return inst

    # -- identifier occurrences --------------------------------------------- #
    def _collect_uses(self, mod):
        text = mod.text
        occ = {}
        for mm, off in ident_tokens(text, mod.body_start):
            nm = mm.group(0)
            if off in mod.skip_off or nm in KEYWORDS or nm in DECL_KEYWORDS:
                continue
            if nm in mod.func_names:
                continue
            before = text[max(0, off - 400):off].rstrip()
            nxt = mm.end()
            while nxt < len(text) and text[nxt] in " \t\r\n":
                nxt += 1
            if nxt < len(text) and text[nxt] == "(":
                continue                       # function/task call
            prev_word = re.search(r"(\w+)$", before)
            prev_word = prev_word.group(1) if prev_word else ""
            # NOTE: never skip on "identifier :" -- that is also how a ternary
            # (cond ? a : b) and a case label look.  Real named-block labels are
            # already in skip_off via _parse_body.
            two, one = text[nxt:nxt + 2], text[nxt:nxt + 1]
            is_write = False
            # A statement may legally start after ; { } : begin end else, and also
            # after the ')' of if/case/for headers -- an expression can never start
            # there, so 'x <=' / 'x =' following ')' is always an assignment.
            stmt_head = bool(re.search(r"([;:{}]\s*$|\b(begin|end)\s*$|\)\s*$)",
                                       before[-40:] or " "))
            if not stmt_head and before.endswith("(") and prev_word == "for":
                stmt_head = True               # for (i = 0; ...)
            # LHS may be a bit/part select:  mem[idx] <= x;  q[3:0] = y;
            op_i = nxt
            if op_i < len(text) and text[op_i] == "[":
                j = find_matching(text, op_i, "[", "]")
                if j > 0:
                    op_i = j + 1
                    while op_i < len(text) and text[op_i] in " \t\r\n":
                        op_i += 1
                    two, one = text[op_i:op_i + 2], text[op_i:op_i + 1]
            eq = (one == "=" and text[op_i + 1:op_i + 2] != "=")
            nblock = two == "<="
            if prev_word == "assign" and eq:
                is_write = True
            elif (nblock or eq) and stmt_head:
                is_write = True
            occ.setdefault(nm, []).append((off, is_write))
        mod.occ = occ


# --------------------------------------------------------------------------- #
# expression width
# --------------------------------------------------------------------------- #

def base_ident(expr):
    m = re.match(r"^([A-Za-z_]\w*)\s*(\[[^\]]*\])?$", (expr or "").strip())
    return m.group(1) if m else None


def expr_width(expr, widths, params, depth=0):
    """Static width of a connection expression, or None if not known."""
    if depth > 10:
        return None
    expr = (expr or "").strip()
    if not expr:
        return 0
    while expr.startswith("(") and find_matching(expr, 0) == len(expr) - 1:
        expr = expr[1:-1].strip()
    m = SIZED_RE.match(expr.replace(" ", ""))
    if m:
        return int(m.group("bits")) if m.group("bits") else 1
    if re.match(r"^\d+$", expr):
        return None                       # unsized literal -> context determined
    m = re.match(r"^([A-Za-z_]\w*)$", expr)
    if m:
        nm = m.group(1)
        if nm in params:
            return None
        if nm in widths:
            return widths[nm]
        return 1                          # implicit 1-bit net
    m = re.match(r"^([A-Za-z_]\w*)\s*\[(.+)\]$", expr, re.S)
    if m and IDENT_RE.match(m.group(1)).group(0) == m.group(1):
        sel = m.group(2).strip()
        pm = re.match(r"^(.*?)\s*(\+|-)\s*:\s*(.+)$", sel, re.S)
        if pm:
            return const_value(pm.group(3), params)
        sp = split_top(sel, ":")
        if len(sp) == 2:
            a = const_value(sp[0][1], params)
            b = const_value(sp[1][1], params)
            if a is not None and b is not None:
                return abs(a - b) + 1
        return None
    if expr.startswith("{") and expr.endswith("}"):
        total = 0
        for _o, part in split_top(expr[1:-1], ","):
            rep = None
            pm = re.match(r"^\s*(.+?)\s*\{([^{}]*)\}\s*$", part, re.S)
            if pm and not re.match(r"^\s*\(", pm.group(1)):
                rep = const_value(pm.group(2), params)
                if rep is None:
                    return None
                part = pm.group(1)
            w = expr_width(part, widths, params, depth + 1)
            if w is None:
                return None
            total += w * (rep if rep else 1)
        return total
    if re.search(r"[?:&|^~!<>=+\-*/%]", expr):
        out = []
        for tok in re.split(r"[?:&|^~!<>=,+\-*/%]+", expr):
            tok = tok.strip()
            if not tok or tok.startswith("'"):
                continue                      # sized literal handled above
            if re.match(r"^\d+$", tok):
                continue                      # unsized: context determined
            w = expr_width(tok, widths, params, depth + 1)
            if w is not None:
                out.append(w)
        return max(out) if out else None
    return None


# --------------------------------------------------------------------------- #
# auditor
# --------------------------------------------------------------------------- #

class Finding(object):
    __slots__ = ("cat", "sub", "sev", "path", "line", "msg", "mod", "inst",
                 "port", "net", "vendor", "key")

    def __init__(self, cat, sub, sev, path, line, msg, mod="", inst="",
                 port="", net="", vendor=False):
        self.cat, self.sub, self.sev = cat, sub, sev
        self.path, self.line, self.msg = path, line, msg
        self.mod, self.inst, self.port, self.net = mod, inst, port, net
        self.vendor = vendor
        self.key = (cat, sub, path, line, mod, inst, port, net)


class Auditor(object):
    def __init__(self, root, src_rel, verbose=False):
        self.root = os.path.abspath(root)
        self.src = os.path.abspath(os.path.join(self.root, src_rel))
        self.roots = [self.src, os.path.join(self.root, "user_source"), self.root]
        self.verbose = verbose
        self.pp = Prepro(base=self.root)
        self.parser = Parser(self.pp)
        self.files, self.skipped = [], []
        self.modules, self.by_name = [], {}
        self.findings = []
        self._seen = set()
        self.notes, self.parse_errors = [], []
        self.blackbox = {}
        self.drive = {}                     # uid -> name -> counts
        self.unauditable = []
        self.roots_modules = []

    # ---- discovery --------------------------------------------------------- #
    def collect_files(self):
        if not os.path.isdir(self.src):
            raise SystemExit("source dir not found: " + self.src)
        for dirpath, dirnames, filenames in os.walk(self.src):
            dirnames[:] = sorted(d for d in dirnames if d not in ("docs",))
            for fn in sorted(filenames):
                if not fn.endswith(".v"):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, fn),
                                       self.root).replace("\\", "/")
                if fn.endswith(SKIP_SUFFIX):
                    self.skipped.append(rel)
                    continue
                self.files.append(rel)
        self.files.sort()
        self.skipped.sort()

    def parse(self):
        self.pp.build_index([self.src])
        for rel in self.files:
            path = os.path.join(self.root, rel)
            try:
                lines = self.pp.run(path, self.roots, disp=rel)
                mods = self.parser.modules_in_file(rel, lines, len(self.modules))
            except Exception as exc:
                self.parse_errors.append("%s: %s" % (rel, exc))
                if self.verbose:
                    import traceback
                    traceback.print_exc()
                continue
            for m in mods:
                self.modules.append(m)
                self.by_name.setdefault(m.name, []).append(m)
                if getattr(m, "no_body", False):
                    self.unauditable.append(
                        "%s (%s) -- port map parsed, body is encrypted/pruned"
                        % (m.name, m.path))
        self.notes.extend(ascii_only(n) for n in self.pp.notes)
        instantiated = set()
        for m in self.modules:
            for i in m.instances:
                instantiated.add(i.mname)
        self.roots_modules = [m for m in self.modules
                              if m.name not in instantiated and not m.is_vendor()]

    # ---- tables ------------------------------------------------------------ #
    def resolve_tables(self):
        for mod in self.modules:
            env = {}
            for _round in range(3):
                changed = False
                for nm, d in mod.params.items():
                    if nm in env:
                        continue
                    v = const_value(d.value, env)
                    if v is not None:
                        env[nm] = v
                        changed = True
                if not changed:
                    break
            mod.env = env
            w = {}
            for p in mod.ports.values():
                w[p.name] = range_width(p.range, env) if p.range else 1
            for nm, d in mod.decls.items():
                w[nm] = range_width(d.range, env) if d.range else 1
            mod.net_w = w

    def resolve_child(self, mname, inst):
        cands = self.by_name.get(mname) or []
        if not cands:
            return None, False
        if len(cands) == 1:
            return cands[0], False
        names = set(c.port for c in inst.conns)
        scored = sorted(cands, key=lambda m: (len(names & set(m.ports)),
                                              0 if m.is_vendor() else 1))
        return scored[-1], True

    def child_port_widths(self, mod, cmod, inst):
        over = dict(inst.params)
        env = {}
        for _round in range(3):
            changed = False
            for nm, d in cmod.params.items():
                if nm in env:
                    continue
                src = over.get(nm, d.value)
                v = const_value(src, env)
                if v is None and src is not None:
                    v = const_value(src, mod.env)
                    if src in mod.env:
                        v = mod.env[src]
                if v is not None:
                    env[nm] = v
                    changed = True
            if not changed:
                break
        for nm, expr in over.items():
            v = const_value(expr, mod.env)
            if v is not None:
                env[nm] = v
        w = {}
        for p in cmod.ports.values():
            w[p.name] = range_width(p.range, env) if p.range else 1
        return w

    def add(self, f):
        if f.key in self._seen:
            return
        self._seen.add(f.key)
        self.findings.append(f)

    # ---- usage table ------------------------------------------------------- #
    def build_usage(self):
        """reads / syntactic writes / instance drives, per module per net.

        An identifier that appears as a port-connection expression is classified
        by the *direction of that port*: driving an output is NOT a read.  This
        is what makes the sc_fd class (".frame_done(sc_fd)" where sc_fd is never
        consumed) detectable at all.
        """
        for mod in self.modules:
            tbl = self.drive.setdefault(mod.uid, {})

            def touch(nm, key):
                st = tbl.setdefault(nm, {"read": 0, "w_sync": 0, "w_inst": 0})
                st[key] += 1

            # 1) classify every connection expression by the child port direction
            kind_by_off = {}
            for inst in mod.instances:
                cmod, _amb = self.resolve_child(inst.mname, inst)
                for c in inst.conns:
                    nm = base_ident(c.expr)
                    if not nm:
                        continue
                    if cmod is None:
                        kind_by_off[c.expr_off] = "read"    # unknown: stay silent
                        continue
                    p = cmod.ports.get(c.port)
                    if p is None:
                        kind_by_off[c.expr_off] = "read"
                        continue
                    kind_by_off[c.expr_off] = {"output": "drive",
                                               "inout": "both"}.get(p.dir or "",
                                                                    "read")
            # 2) walk the syntactic occurrences, honouring that classification
            for nm, occ in mod.occ.items():
                for off, is_write in occ:
                    kind = kind_by_off.get(off)
                    if kind == "drive":
                        touch(nm, "w_inst")
                    elif kind == "both":
                        touch(nm, "w_inst")
                        touch(nm, "read")
                    elif kind == "read":
                        touch(nm, "read")
                    elif is_write:
                        touch(nm, "w_sync")
                    else:
                        touch(nm, "read")
            for nm in mod.init_driven:
                touch(nm, "w_sync")
        self.usage = self.drive

    # ---- categories 1..4 --------------------------------------------------- #
    def check_instantiations(self):
        for mod in self.modules:
            tbl = self.usage.get(mod.uid, {})
            for inst in mod.instances:
                cmod, ambiguous = self.resolve_child(inst.mname, inst)
                if cmod is None:
                    self.blackbox[inst.mname] = self.blackbox.get(inst.mname, 0) + 1
                    continue
                cw = self.child_port_widths(mod, cmod, inst)
                conns = OrderedDict()
                for c in inst.conns:
                    conns.setdefault(c.port, c)
                    if len([x for x in inst.conns if x.port == c.port]) > 1:
                        self.add(Finding("bad_port", "DUPLICATE", "HIGH",
                                         *mod.at(c.port_off),
                                         "%s.%s: port '%s' connected twice"
                                         % (inst.mname, inst.iname, c.port),
                                         mod.name, inst.iname, c.port,
                                         vendor=mod.is_vendor()))
                label = "%s.%s" % (inst.mname, inst.iname or "<anon>")
                ifile, iline = mod.at(inst.off)
                dup_note = " (module name is defined more than once: %s)" % \
                    ", ".join(m.path for m in self.by_name[inst.mname]) \
                    if ambiguous and inst.mname in self.by_name else ""
                # ---- category 4
                for c in inst.conns:
                    if c.port in cmod.ports:
                        continue
                    f_, l_ = mod.at(c.port_off)
                    self.add(Finding(
                        "bad_port", "NOT_ON_MODULE", "CRITICAL", f_, l_,
                        "%s: port name '%s' does not exist on module '%s' (%s%s) "
                        "-> TD turns it into an implicit net"
                        % (label, c.port, inst.mname, cmod.path, dup_note),
                        mod.name, inst.iname, c.port, vendor=mod.is_vendor()))
                # ---- categories 1, 2, 3
                for pname, p in cmod.ports.items():
                    direction = p.dir or "input"
                    c = conns.get(pname)
                    if c is None:
                        if direction == "output":
                            self.add(Finding(
                                "unconnected_out", "OMIT", "CRITICAL", ifile, iline,
                                "%s: output '%s' is not present in the connection "
                                "list at all" % (label, pname), mod.name,
                                inst.iname, pname, vendor=mod.is_vendor()))
                        else:
                            self.add(Finding(
                                "unconnected_in", "OMIT", "LOW", ifile, iline,
                                "%s: %s '%s' is not present in the connection list"
                                % (label, direction, pname), mod.name, inst.iname,
                                pname, vendor=mod.is_vendor()))
                        continue
                    expr = c.expr
                    cfile, cline = mod.at(c.expr_off)
                    if direction == "output":
                        if not expr:
                            self.add(Finding(
                                "unconnected_out", "EMPTY", "CRITICAL", cfile, cline,
                                "%s: output '%s' explicitly left unconnected "
                                "(.%s( ))" % (label, pname, pname), mod.name,
                                inst.iname, pname, vendor=mod.is_vendor()))
                        else:
                            nm = base_ident(expr)
                            st = tbl.get(nm) if nm else None
                            if (nm and st and nm not in mod.ports
                                    and nm not in mod.params
                                    and st["read"] == 0
                                    and (st["w_inst"] + st["w_sync"]) > 0):
                                d_off = (mod.decls[nm].off if nm in mod.decls
                                         else c.expr_off)
                                df, dl = mod.at(d_off)
                                self.add(Finding(
                                    "unconnected_out", "DEAD", "CRITICAL", cfile,
                                    cline,
                                    "%s: output '%s' drives '%s' (declared %s:%d), "
                                    "which nothing ever reads -> silently "
                                    "disconnected net"
                                    % (label, pname, nm, df, dl),
                                    mod.name, inst.iname, pname, net=nm,
                                    vendor=mod.is_vendor()))
                    elif not expr:
                        self.add(Finding(
                            "unconnected_in", "EMPTY", "LOW", cfile, cline,
                            "%s: %s '%s' left unconnected" % (label, direction,
                                                              pname), mod.name,
                            inst.iname, pname, vendor=mod.is_vendor()))
                    elif is_constant(expr):
                        self.add(Finding(
                            "unconnected_in", "TIED", "LOW", cfile, cline,
                            "%s: %s '%s' tied to constant %s"
                            % (label, direction, pname, expr), mod.name,
                            inst.iname, pname, vendor=mod.is_vendor()))
                    fw = cw.get(pname)
                    if fw is None or not expr:
                        continue
                    aw = expr_width(expr, mod.net_w, mod.env)
                    if aw is None or aw == fw:
                        continue
                    self.add(Finding(
                        "width", "MISMATCH", "MEDIUM", cfile, cline,
                        "%s: %s '%s' is %d bit but the connected expression is "
                        "%d bit (%s) [%s]"
                        % (label, direction, pname, fw, aw,
                           "actual wider -> truncated" if aw > fw
                           else "actual narrower -> zero-extends/sign-extends",
                           short(expr)), mod.name, inst.iname, pname,
                        vendor=mod.is_vendor()))

    # ---- category 5 -------------------------------------------------------- #
    def check_implicit(self):
        for mod in self.modules:
            if getattr(mod, "no_body", False):
                continue                 # body unreadable: nothing to judge
            declared = OrderedDict()
            for nm, p in mod.ports.items():
                declared.setdefault(nm, p.off)
            for nm, d in mod.decls.items():
                declared.setdefault(nm, d.off)
            for nm, d in mod.params.items():
                declared.setdefault(nm, d.off)
            for nm in mod.func_names:
                declared.setdefault(nm, mod.body_start)
            for nm, occ in sorted(mod.occ.items()):
                first = min(o for o, _w in occ)
                if nm not in declared:
                    f_, l_ = mod.at(first)
                    self.add(Finding(
                        "implicit", "NEVER_DECLARED", "HIGH", f_, l_,
                        "%s: '%s' is never declared in this module -> implicit "
                        "1-bit wire (TD HDL-1007)" % (mod.name, nm), mod.name,
                        net=nm, vendor=mod.is_vendor()))
                    continue
                if declared[nm] > first:
                    uf, ul = mod.at(first)
                    df, dl = mod.at(declared[nm])
                    self.add(Finding(
                        "implicit", "DECLARE_AFTER_USE", "HIGH", df, dl,
                        "%s: '%s' is already implicitly declared on line %d "
                        "(first use %s:%d, declaration %s:%d -> TD HDL-7225)"
                        % (mod.name, nm, ul, os.path.basename(uf), ul,
                           os.path.basename(df), dl), mod.name, net=nm,
                        vendor=mod.is_vendor()))

    # ---- category 6 -------------------------------------------------------- #
    def check_usage(self):
        for mod in self.modules:
            if getattr(mod, "no_body", False):
                continue                 # body unreadable: nothing to judge
            tbl = self.usage.get(mod.uid, {})
            for nm, st in sorted(tbl.items()):
                if nm in mod.ports or nm in mod.params:
                    continue
                d = mod.decls.get(nm)
                if d is None:
                    continue                       # implicit: covered by category 5
                if d.kind.endswith("(local)"):
                    continue                     # function/task arg or local
                f_, l_ = mod.at(d.off)
                driven = st["w_sync"] + st["w_inst"]
                if driven and not st["read"]:
                    if st["w_inst"] and not st["w_sync"]:
                        continue                   # the sc_fd class -> category 1
                    self.add(Finding(
                        "usage", "DEAD_WRITE", "MEDIUM", f_, l_,
                        "%s: '%s' (%s) is written but never read -> dead register/net"
                        % (mod.name, nm, d.kind), mod.name, net=nm,
                        vendor=mod.is_vendor()))
                elif st["read"] and not driven:
                    self.add(Finding(
                        "usage", "NEVER_WRITE", "HIGH", f_, l_,
                        "%s: '%s' (%s) is read but never driven -> stuck-at-Z "
                        "candidate" % (mod.name, nm, d.kind), mod.name, net=nm,
                        vendor=mod.is_vendor()))
            for p in mod.ports.values():
                st = tbl.get(p.name, {})
                f_, l_ = mod.at(p.off)
                if p.dir == "output":
                    if not st.get("w_sync") and not st.get("w_inst"):
                        self.add(Finding(
                            "usage", "PORT_UNDRIVEN", "HIGH", f_, l_,
                            "%s: output port '%s' has no driver inside the module"
                            % (mod.name, p.name), mod.name, port=p.name,
                            vendor=mod.is_vendor()))
                elif p.dir == "input":
                    if not st.get("read") and p.name not in tbl:
                        self.add(Finding(
                            "usage", "PORT_UNUSED", "LOW", f_, l_,
                            "%s: input port '%s' is never read inside the module"
                            % (mod.name, p.name), mod.name, port=p.name,
                            vendor=mod.is_vendor()))

    # ---- drive ------------------------------------------------------------- #
    def run(self):
        self.collect_files()
        self.parse()
        self.resolve_tables()
        self.build_usage()
        self.check_instantiations()
        self.check_implicit()
        self.check_usage()
        self.findings.sort(key=lambda f: (SEV_RANK[f.sev], f.vendor, f.path,
                                          f.line, f.cat))
        return self

    def counts(self):
        c = OrderedDict((k, 0) for k in CATS)
        for f in self.findings:
            c[f.cat] += 1
        return c


def is_constant(expr):
    expr = expr.strip()
    if SIZED_RE.match(expr.replace(" ", "")):
        return True
    return bool(re.match(r"^\d+$", expr))


def short(expr, n=38):
    expr = " ".join(expr.split())
    return expr if len(expr) <= n else expr[:n - 3] + "..."


# --------------------------------------------------------------------------- #
# reporting
# --------------------------------------------------------------------------- #

CAT_TITLE = OrderedDict([
    ("unconnected_out",
     "CATEGORY 1  UNCONNECTED OUTPUTS  -- submodule outputs that reach nothing"),
    ("bad_port",
     "CATEGORY 4  NONEXISTENT PORT NAMES  -- typos that become implicit nets"),
    ("implicit",
     "CATEGORY 5  IMPLICIT NETS  -- TD's HDL-7225 / HDL-1007 class"),
    ("width",
     "CATEGORY 3  WIDTH MISMATCHES  -- formal port vs. connected expression"),
    ("usage",
     "CATEGORY 6  DEAD / UNDRIVEN NETS  -- dead registers, stuck-at-Z"),
    ("unconnected_in",
     "CATEGORY 2  INPUTS unconnected or tied  -- review list, often legitimate"),
])
JUDGEMENT = {
    "unconnected_out":
        "LOW judgement needed for DEAD/EMPTY (a fact about the netlist); OMIT hits "
        "inside generated IP are frequently deliberate, so read user-RTL ones first",
    "bad_port":
        "ZERO judgement needed: a port name that is not on the definition is always "
        "a typo or a stale IP pin",
    "implicit":
        "LOW judgement, with one caveat: function/task locals are treated as "
        "module-scope declarations, so a genuinely implicit name inside one routine "
        "could be masked",
    "width":
        "MEDIUM judgement: only statically known widths are compared (arithmetic and "
        "ternary expressions are skipped), and constant tie-offs like 24'd0 into a "
        "21-bit port are harmless though technically real",
    "usage":
        "HIGH judgement: nets used only inside disabled `ifdef branches, hierarchical "
        "references, and vendor wrappers all land here.  Treat as a review queue",
    "unconnected_in":
        "INFORMATIONAL: tying a spare input to 1'b0 is normal; this list exists so a "
        "reviewer signs off on each one",
}


def report(a, args, out):
    w = lambda s="": out.append(ascii_only(s))
    uc = a.counts()
    w("=" * 78)
    w("lint_ports.py -- static RTL structural audit")
    w("root : %s" % a.root.replace("\\", "/"))
    w("src  : %s" % os.path.relpath(a.src, a.root).replace("\\", "/"))
    w("=" * 78)
    w("files scanned       : %d (.v, %s skipped as vendor sim models)"
      % (len(a.files), len(a.skipped)))
    if a.skipped:
        w("  skipped: %s" % ", ".join(os.path.basename(s) for s in a.skipped))
        w("  (the sibling generated wrappers under IP/ are readable and were")
        w("   parsed, so the FIFO port maps used below come from them)")
    w("modules / sites     : %d modules, %d instantiation sites"
      % (len(a.modules), sum(len(m.instances) for m in a.modules)))
    if a.roots_modules:
        w("top candidates      : %s" % ", ".join(m.name for m in a.roots_modules[:8]))
    w("parse failures      : %d" % len(a.parse_errors))
    for e in a.parse_errors:
        w("  ! " + e)
    bb = sorted(a.blackbox.items(), key=lambda kv: -kv[1])
    w("black-box instances : %d distinct module names (no definition in the tree;"
      % len(bb))
    w("                       categories 1-4 are skipped for these)")
    if bb:
        names = ", ".join("%s x%d" % (n, c) for n, c in bb[:10])
        w("  %s%s" % (names, " ..." if len(bb) > 10 else ""))
    for n in a.notes:
        w("note: %s" % n)
    if a.unauditable:
        w("modules with an unreadable body (`pragma protect encrypted IP):")
        for n in a.unauditable:
            w("  %s" % n)
        w("  -> their port maps ARE used to check the parents that instantiate")
        w("     them; their own internals (categories 5 and 6) are not audited.")
    w("")
    w("severity summary: " + "  ".join(
        "%s=%d" % (s, sum(1 for f in a.findings if f.sev == s))
        for s in ("CRITICAL", "HIGH", "MEDIUM", "LOW")))
    w("")
    for cat, title in CAT_TITLE.items():
        hits = [f for f in a.findings if f.cat == cat]
        if args.no_vendor:
            hits = [f for f in hits if not f.vendor]
        w("-" * 78)
        w(title)
        if not hits:
            w("  none")
            w("-" * 78)
            w("")
            continue
        w("-" * 78)
        subs = OrderedDict()
        for f in hits:
            subs[f.sub] = subs.get(f.sub, 0) + 1
        w("  by subtype: " + "  ".join("%s=%d" % kv for kv in subs.items()))
        files = {}
        for f in hits:
            if not f.vendor:
                files[f.path] = files.get(f.path, 0) + 1
        if files:
            top = sorted(files.items(), key=lambda kv: -kv[1])[:4]
            w("  user files most hit: " + ", ".join(
                "%s(%d)" % (os.path.basename(p), n) for p, n in top))
        if cat == "unconnected_out":
            w("  total %d   (user RTL %d / generated+vendor %d)"
              % (len(hits), sum(1 for f in hits if not f.vendor),
                 sum(1 for f in hits if f.vendor)))
            w("  trust: " + JUDGEMENT[cat])
            for sub in ("DEAD", "EMPTY", "OMIT"):
                group = [f for f in hits if f.sub == sub
                         and (args.all or not f.vendor)]
                if not group:
                    continue
                w("  --- %s (%d) ---" % (sub, len(group)))
                for f in group:
                    w("  %-9s %s:%d" % (f.sub, f.path, f.line))
                    w("           " + ascii_only(f.msg))
        else:
            shown = [f for f in hits if args.all or not f.vendor]
            hidden = len(hits) - len(shown)
            limit = args.limit or len(shown)
            for f in shown[:limit]:
                w("  %-9s %s:%d" % (f.sub, f.path, f.line))
                w("           " + ascii_only(f.msg))
            if len(shown) > limit:
                w("  ... %d more in this category (--limit 0 to show all)"
                  % (len(shown) - limit))
            if hidden:
                w("  (%d further hits in generated/vendor files -- use --all)"
                  % hidden)
            w("  trust: " + JUDGEMENT[cat])
        w("")
    w("=" * 78)
    w("findings: unconnected_out=%d bad_port=%d width=%d implicit=%d "
      "(unconnected_in=%d usage=%d)"
      % (uc["unconnected_out"], uc["bad_port"], uc["width"], uc["implicit"],
         uc["unconnected_in"], uc["usage"]))
    u = sum(1 for f in a.findings if not f.vendor)
    w("of which user RTL: %d   generated/vendor: %d" % (u, len(a.findings) - u))
    w("=" * 78)


# --------------------------------------------------------------------------- #
# self tests
# --------------------------------------------------------------------------- #

def check_known(a):
    """Prove the auditor still finds the three bugs we know are real.

    Matching is line-exact on purpose: a tool that finds 'a' full_flag but not
    the second one at its own line is not finished.
    """
    ok = True
    for cat, sub, needle, fbase, line in KNOWN_TARGETS:
        same = [f for f in a.findings if f.cat == cat and f.sub == sub
                and os.path.basename(f.path) == fbase
                and (needle in (f.net or "") or needle in (f.port or ""))]
        exact = [f for f in same if f.line == line]
        chosen = exact[0] if exact else (same[0] if same else None)
        status = "PASS" if exact else "FAIL"
        ok = ok and bool(exact)
        detail = "NOT FOUND (auditor is broken)"
        if chosen is not None and not exact:
            detail = "found only at %s:%d, expected line %d" % (chosen.path,
                                                                chosen.line, line)
        elif chosen is not None:
            detail = "%s:%d  %s" % (chosen.path, chosen.line,
                                    short(chosen.msg, 58))
        print("  %s  %-9s %-12s %s:%d  -> %s"
              % (status, sub, needle, fbase, line, detail))
    return ok


def td_compare(a, pattern):
    """Compare category 5 against TD's own HDL-7225 (and HDL-5373) log lines.

    TD emits two related messages:
      HDL-7225 CRITICAL-WARNING  "'x' is already implicitly declared on line N"
      HDL-5373 WARNING           "identifier 'x' is used before its declaration"
    Both mean "use precedes declaration"; TD only promotes a use to a real
    implicit net when it happens in a port connection.  This tool reports the
    union, so the interesting question is whether the 7225 set is reproduced.
    """
    td72, td53 = {}, {}
    logs = sorted(glob.glob(pattern))
    for log in logs:
        try:
            txt = io.open(log, encoding="utf-8", errors="replace").read()
        except (IOError, OSError):
            continue
        for mm in re.finditer(r"HDL-7225.*?'(\w+)'.*?([\w./\-]+\.(?:v|vh))\((\d+)\)",
                              txt):
            td72[(mm.group(1), os.path.basename(mm.group(2)), int(mm.group(3)))] = log
        for mm in re.finditer(r"HDL-5373.*?'(\w+)'.*?([\w./\-]+\.(?:v|vh))\((\d+)\)",
                              txt):
            td53[(mm.group(1), os.path.basename(mm.group(2)), int(mm.group(3)))] = log
    mine = {}
    for f in a.findings:
        if f.cat == "implicit" and f.sub == "DECLARE_AFTER_USE":
            mine[(f.net, os.path.basename(f.path), f.line)] = f
    print("  TD log files matched      : %d" % len(logs))
    print("  TD HDL-7225 unique        : %d" % len(td72))
    print("  mine DECLARE_AFTER_USE    : %d" % len(mine))
    print("  HDL-7225 reproduced exactly: %d / %d" % (len(set(td72) & set(mine)),
                                                      len(td72)))
    missing = sorted(set(td72) - set(mine))
    extra = sorted(set(mine) - set(td72))
    explained = [x for x in extra if x in td53 or x[0] in
                 {k[0] for k in td53}]
    unexplained = [x for x in extra if x not in explained]
    for nm, base, ln in missing:
        print("  MISSED (TD says implicit, we do not): %s @ %s:%d" % (nm, base, ln))
    for nm, base, ln in explained:
        print("  extra-but-explained: %s @ %s:%d = TD HDL-5373 (use before "
              "declaration, no implicit net created by TD)" % (nm, base, ln))
    for nm, base, ln in unexplained:
        print("  extra-unexplained:   %s @ %s:%d" % (nm, base, ln))
    if not missing and not unexplained:
        print("  VERDICT: counts agree -- our category 5 is exactly TD's HDL-7225 "
              "set plus TD's own HDL-5373 list")
    return not missing and not unexplained


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

def main(argv=None):
    ap = argparse.ArgumentParser(
        description="static RTL structural auditor (ports / nets / widths)")
    ap.add_argument("--root", default=os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))),
        help="project root (default: parent of tools/)")
    ap.add_argument("--src", default=DEFAULT_SRC, help="RTL dir, relative to --root")
    ap.add_argument("--all", action="store_true",
                    help="include generated/vendor file findings inline")
    ap.add_argument("--no-vendor", action="store_true",
                    help="drop generated/vendor findings entirely")
    ap.add_argument("--limit", type=int, default=120,
                    help="max hits printed per category (0 = all)")
    ap.add_argument("--json", action="store_true", help="machine readable output")
    ap.add_argument("--check-known", action="store_true",
                    help="regression self test (sc_fd + the two full_flag pins)")
    ap.add_argument("--td-compare", metavar="GLOB", default=None,
                    help="compare category 5 against HDL-7225 lines in TD logs")
    ap.add_argument("--no-gate-vendor", action="store_true", default=True,
                    help="vendor-only findings do not fail the exit code (default)")
    ap.add_argument("--gate-all", action="store_true",
                    help="let vendor findings fail the gate too")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    src_rel = args.src if not os.path.isabs(args.src) \
        else os.path.relpath(args.src, args.root)
    try:
        a = Auditor(args.root, src_rel, verbose=args.verbose).run()
    except SystemExit:
        raise
    except Exception as exc:
        sys.stderr.write("lint_ports: internal error: %s\n" % exc)
        if args.verbose:
            import traceback
            traceback.print_exc()
        return 2

    bad = a.counts()["unconnected_out"] + a.counts()["bad_port"]
    if not args.gate_all:
        bad = sum(1 for f in a.findings
                  if f.cat in ("unconnected_out", "bad_port") and not f.vendor)

    if args.json:
        payload = OrderedDict([
            ("root", a.root.replace("\\", "/")), ("files", a.files),
            ("skipped", a.skipped), ("modules", len(a.modules)),
            ("sites", sum(len(m.instances) for m in a.modules)),
            ("blackbox", a.blackbox), ("notes", a.notes),
            ("unauditable", a.unauditable),
            ("parse_errors", a.parse_errors), ("counts", a.counts()),
            ("gate_hits", bad), ("gate_pass", bad == 0),
            ("findings", [OrderedDict([("cat", f.cat), ("sub", f.sub),
                                       ("sev", f.sev), ("path", f.path),
                                       ("line", f.line), ("module", f.mod),
                                       ("instance", f.inst), ("port", f.port),
                                       ("net", f.net), ("vendor", f.vendor),
                                       ("msg", ascii_only(f.msg))])
                          for f in a.findings]),
        ])
        print(json.dumps(payload, indent=1, ensure_ascii=True))
    else:
        out = []
        report(a, args, out)
        print("\n".join(out))

    gate_line = ("gate: category1+category4 = %d (user RTL unless --gate-all) -> %s"
                 % (bad, "FAIL" if bad else "PASS"))
    known_ok = True
    notes = [gate_line]
    if args.check_known:
        notes.append("== known-bug regression (must all PASS) ==")
        buf = io.StringIO()
        saved = sys.stdout
        try:
            sys.stdout = buf
            known_ok = check_known(a)
        finally:
            sys.stdout = saved
        notes.extend(buf.getvalue().rstrip().splitlines())
        if not known_ok:
            notes.append("REGRESSION: the auditor lost a known-real finding")
    if args.td_compare:
        notes.append("== TD HDL-7225 cross-check ==")
        buf = io.StringIO()
        saved = sys.stdout
        try:
            sys.stdout = buf
            td_compare(a, args.td_compare)
        finally:
            sys.stdout = saved
        notes.extend(buf.getvalue().rstrip().splitlines())
    if args.json:
        # keep stdout pure JSON: the human/gate lines go to stderr
        sys.stderr.write("\n".join(notes) + "\n")
    else:
        print("\n".join(notes))
    if not known_ok:
        return 3                       # the auditor itself regressed: loudest code
    if bad:
        return 1                       # CI gate: category 1 / category 4 present
    return 0

if __name__ == "__main__":
    sys.exit(main())
