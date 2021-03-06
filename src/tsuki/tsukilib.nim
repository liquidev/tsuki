## tsuki's standard library.

import chunk
import common
import value
import vm

type
  Range* = Slice[float]
    ## A tsuki range.

  Countup* = ref object
    ## A tsuki countup iterator.
    lo, hi, stride: int
    i: int

  Countdown* = ref object
    ## A tsuki countdown iterator.
    hi, lo, stride: int
    i: int

proc addSystemModule*(cs: CompilerState, a: Assembly): Module =

  var
    filenameId = cs.addFilename("system.tsu")
    chunk = newChunk(filenameId)
    m = newModule(chunk)

  template equality(vt: int) =

    a.addMethod vt, "==", 2,
      wrap proc (s: State, args: openArray[Value]): Value =
        args[0] == args[1]

    a.addMethod vt, "!=", 2,
      wrap proc (s: State, args: openArray[Value]): Value =
        args[0] != args[1]

  let mDollar = a.getMethodId("$", 1)

  #---
  # toplevel
  #---

  # echo(_)
  m.addProc a, "echo", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      let maybeStrVal = s.safeCall(mDollar, args[0])
      if maybeStrVal.isSome:
        let strVal = maybeStrVal.get
        s.assert(strVal.isString, "echo expects a string")
        let str = strVal.getString
        echo str
      else:
        echo $args[0]
      result = tsukiNil

  # abort(_)
  m.addProc a, "abort", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      s.assert(args[0].isString, "abort expects an error message string")
      s.setError(args[0].getString)

  #---
  # Nil
  #---

  # not
  a.addMethod vtableNil, "not", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      tsukiTrue

  # $
  a.addMethod vtableNil, "$", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      "nil"

  equality vtableNil

  #---
  # Bool
  #---

  # not
  a.addMethod vtableBool, "not", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      if args[0].isTrue: tsukiFalse
      else: tsukiTrue

  # $
  a.addMethod vtableBool, "$", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      if args[0].isTrue: "true"
      else: "false"

  equality vtableBool

  #--
  # Float
  #--

  proc isInt(f: float64): bool {.nimcall.} =
    f.int.float == f

  # $
  a.addMethod vtableFloat, "$", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      let f = args[0].getFloat
      if f.isInt:
        $f.int
      else:
        $f

  # arithmetic

  a.addMethod vtableFloat, "-", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      -args[0].getFloat

  block binary:

    template binaryOp(name: string, op: untyped) =
      a.addMethod vtableFloat, name, 2,
        proc (s: State, args: openArray[Value]): Value =
          s.assert(args[1].isFloat, "second operand must be a Float")
          `op`(args[0].getFloat, args[1].getFloat)

    binaryOp "+", `+`
    binaryOp "-", `-`
    binaryOp "*", `*`
    binaryOp "/", `/`

    binaryOp "<", `<`
    binaryOp "<=", `<=`
    binaryOp ">", `>`
    binaryOp ">=", `>=`

  equality vtableFloat

  a.addMethod vtableFloat, "isInt", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      args[0].getFloat.isInt

  #--
  # String
  #--

  # $
  a.addMethod vtableString, "$", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      args[0].getString

  equality vtableString

  #--
  # Range
  #--

  let vtableRange = a.addVtable("Range")

  # Float: ..
  a.addMethod vtableFloat, "..", 2,
    wrap proc (s: State, args: openArray[Value]): Value =
      s.assert(args[1].isFloat, "second operand must be a Float")
      initValue(vtableRange, args[0].getFloat..args[1].getFloat)

  # Float: ..<
  a.addMethod vtableFloat, "..<", 2,
    wrap proc (s: State, args: openArray[Value]): Value =
      s.assert(args[1].isFloat, "second operand must be a Float")
      initValue(vtableRange, args[0].getFloat..args[1].getFloat - 1)

  # $
  a.addMethod vtableRange, "$", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      let r = args[0].getNimData(Range)
      $r.a & ".." & $r.b

  #--
  # Countup
  #--

  let vtableCountup = a.addVtable("Countup")

  # Range: _iterate, countup
  block:

    proc impl(s: State, args: openArray[Value]): Value =
      let r = args[0].getNimData(Range)
      result = initValue(
        vtableCountup,
        block:
          var c = Countup(
            lo: min(r.a.int, r.b.int), hi: max(r.a.int, r.b.int),
            stride: 1,
          )
          c.i = c.lo
          c
      )

    a.addMethod vtableRange, "_iterate", 1, wrap impl
    a.addMethod vtableRange, "countup", 1, wrap impl

  # Range: countup(_)
  a.addMethod vtableRange, "countup", 2,
    wrap proc (s: State, args: openArray[Value]): Value =
      s.assert(args[1].isFloat, "first argument must be a Float")
      let
        r = args[0].getNimData(Range)
        stride = args[1].getFloat.int
      initValue(
        vtableCountup,
        block:
          var c = Countup(
            lo: min(r.a.int, r.b.int), hi: max(r.a.int, r.b.int),
            stride: stride,
          )
          c.i = c.lo
          c
      )

  # _iterate
  a.addMethod vtableCountup, "_iterate", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      args[0]

  # _hasNext
  a.addMethod vtableCountup, "_hasNext", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      let it = args[0].getNimData(Countup)
      it.i <= it.hi

  # _next
  a.addMethod vtableCountup, "_next", 1,
    wrap proc (s: State, args: openArray[Value]): Value =
      let it = args[0].getNimData(Countup)
      result = it.i.float
      inc it.i


  result = m
