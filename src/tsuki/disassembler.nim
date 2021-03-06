## Disassembler for codegen and VM debugging purposes.

import std/strutils

import chunk

const
  longestOpcodeLen = block:
    var m = 0
    for o in Opcode:
      m = max(m, ($o)[3..^1].len)
    m

proc disassemble*(chunk: Chunk, a: Assembly): string =
  ## Disassembles the chunk into a human-readable string representation.

  var
    pc = 0
    dest = ""

  while pc < chunk.bytecode.len:
    dest.setLen(0)

    dest.add(pc.BiggestUInt.toHex(8))
    dest.add("  ")

    let (line, column) = chunk.getLineInfo(pc)
    dest.add(alignLeft($line & ":" & $column, 8))

    let opcode = chunk.readOpcode(pc)
    dest.add(($opcode)[3..^1].alignLeft(longestOpcodeLen + 2))

    case opcode

    of opcPushNil, opcPushTrue, opcPushFalse: discard

    of opcPushFloat:
      dest.add($chunk.readFloat(pc))

    of opcPushString:
      let s = chunk.readString(pc)
      dest.add("<" & $s.len & "> ")
      dest.add(escape s)

    of opcPushGlobal, opcPopToGlobal, opcAssignToGlobal:
      dest.add("%%")
      dest.add($chunk.readU16(pc))

    of opcPushLocal, opcPopToLocal, opcAssignToLocal:
      dest.add("%")
      dest.add($chunk.readU16(pc))

    of opcNewObject:
      let vid = int chunk.readU16(pc)
      dest.add('&')
      dest.addInt(vid)
      dest.add(' ')
      dest.add(a.vtables[vid].name)
      dest.add(" {")
      dest.add($chunk.readU8(pc))
      dest.add('}')

    of opcPushField, opcAssignToField:
      dest.add('.')
      dest.add($chunk.readU8(pc))

    of opcJumpFwd, opcJumpFwdIfFalsey:
      let
        offset = chunk.readU16(pc)
        destination = pc + offset.int
      dest.add("-> ")
      dest.add(destination.BiggestUInt.toHex(8))

    of opcJumpBack:
      let
        offset = chunk.readU16(pc)
        destination = pc - offset.int
      dest.add("-> ")
      dest.add(destination.BiggestUInt.toHex(8))

    of opcCallProc:
      let id = int chunk.readU16(pc)
      dest.add("::")
      dest.addInt(id)
      dest.add(' ')
      dest.add(a.procedures[id].name)

    of opcCallMethod:
      let id = int chunk.readU16(pc)
      dest.add(":")
      dest.addInt(id)
      dest.add(' ')
      dest.add($a.getMethodSignature(id))

    of opcDiscard:
      dest.add($chunk.readU8(pc))

    of opcReturn, opcHalt: discard

    dest.add('\n')
    result.add(dest)
