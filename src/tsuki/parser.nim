import std/strutils

import ast
import common
import errors
import lexer


# general

template parseCommaSep(l: var Lexer, dest: var seq[Node], fin: static TokenKind,
                       rule: untyped) =
  ## Parses a comma-separated list of ``rule``.

  while true:
    case l.peek().kind
    of tkEof:
      l.error(peTokenMissing % $fin)
    of fin:
      discard l.next()
      break
    else: discard
    dest.add(`rule`)
    case l.next().kind
    of tkComma: continue
    of fin: break
    else:
      l.error(peXExpected % "',' or '" & $fin & "'")

proc parseExpr(l: var Lexer, precedence = -1): Node

proc parseStmt(l: var Lexer): Node

proc parseBlock(l: var Lexer, dest: var seq[Node],
                parentIndentLevel: int) =
  ## Parses a block with the given indent level. If a token with an indent level
  ## smaller than ``parentIndentLevel`` is found, the block is ended.
  ## If the token directly after the block's start has an indent level smaller
  ## than ``parentIndentLevel``, a single expression is parsed.
  ## The expression's indent level must match ``parentIndentLevel``.

  var
    count = 0
    indentLevel = -1

  while true:

    # indent level validation

    let next = l.peek()
    if next.indentLevel <= parentIndentLevel:
      if count == 0:
        if next.indentLevel != parentIndentLevel:
          l.error(next, peIndentLevel % [">=" & $parentIndentLevel,
                                         $next.indentLevel])
        dest.add(l.parseExpr())
      break

    if indentLevel == -1:
      indentLevel = next.indentLevel
    else:
      if next.indentLevel != indentLevel:
        l.error(peIndentLevel % [$indentLevel, $next.indentLevel])

    # the actual statement part
    dest.add(l.parseStmt())
    l.skip(tkSemi)
    inc count

proc parseBlock(l: var Lexer, dest: var seq[Node],
                fin: static set[TokenKind]) {.deprecated.} =
  ## Parses a block that ends with ``fin``.
  ## This is kept here temporarily and superseded by the other parseBlock,
  ## until I don't implement a fully indentation sensitive grammar.

  while true:
    if l.atEnd:
      l.error(peTokenMissing % $fin)
    if l.peek().kind in fin:
      break
    dest.add(l.parseStmt())
    l.skip(tkSemi)

proc parseBlockExprOrStmt(l: var Lexer, token: Token, isStmt: bool): Node =
  ## Parses a block expression or statement.

  let nodeKind =
    if isStmt: nkBlockStmt
    else: nkBlockExpr
  var stmts = nkStmtList.tree()
  result = nodeKind.tree(stmts).lineInfoFrom(token)
  l.parseBlock(stmts.sons, token.indentLevel)

proc parseIf(l: var Lexer, token: Token, isStmt: bool): Node =
  ## Parses an if expression or statement.

  let
    indentLevel = token.indentLevel
    astKind =
      if isStmt: nkIfStmt
      else: nkIfExpr
  result = astKind.tree().lineInfoFrom(token)

  var hasElse = false
  while true:
    var
      condition = l.parseExpr()
      stmts = nkStmtList.tree().lineInfoFrom(l.peek())
      branch = nkIfBranch.tree(condition, stmts).lineInfoFrom(condition)
    l.parseBlock(stmts.sons, indentLevel)
    result.add(branch)

    let next = l.peek()
    if next.kind in {tkElif, tkElse}:
      discard l.next()
      if next.indentLevel != indentLevel:
        l.error(next, peIndentLevel % [$indentLevel, $next.indentLevel])
      if next.kind == tkElif:
        continue
      else:
        hasElse = true
        break
    else:
      break

  if hasElse:
    var
      stmts = nkStmtList.tree().lineInfoFrom(l.peek())
      branch = nkElseBranch.tree(stmts).lineInfoFrom(stmts)
    l.parseBlock(stmts.sons, indentLevel)
    result.add(branch)

proc parseProc(l: var Lexer, token: Token, anonymous: static bool): Node =
  ## Parses a procedure or a closure.

  let indentLevel = token.indentLevel

  var name = emptyNode().lineInfoFrom(token)
  if not anonymous:
    let nameToken =
      l.expect({tkIdent, tkOperator}, peXExpected % "procedure name")
    var nameStr =
      case nameToken.kind
      of tkIdent: nameToken.ident
      of tkOperator: nameToken.operator
      else: "<invalid>"
    if l.peekOperator("="):
      discard l.next()
      nameStr.add('=')
    name = identNode(nameStr).lineInfoFrom(nameToken)

  var params = emptyNode().lineInfoFrom(name)
  if l.peek().kind == tkLParen:
    let paren = l.next()
    params = nkParamList.tree().lineInfoFrom(paren)
    l.parseCommaSep(params.sons, tkRParen):
      let nameToken = l.expect(tkIdent, peXExpected % "parameter name")
      identNode(nameToken)

  var body = nkStmtList.tree().lineInfoFrom(l.peek())
  if l.peekOperator("=>"):
    let eqToken = l.next()
    if l.peekOperator("..."):
      body = emptyNode().lineInfoFrom(l.next())
    else:
      body.add(nkReturn.tree(l.parseExpr()).lineInfoFrom(eqToken))
  else:
    l.parseBlock(body.sons, indentLevel)

  let astKind =
    if anonymous: nkClosure
    else: nkProc
  result = astKind.tree(name, params, body).lineInfoFrom(token)

const
  pathPrecedence = 11

proc parsePrefix(l: var Lexer, token: Token): Node =
  ## Parses a prefix expression.

  case token.kind
  of tkNil: result = nilNode()
  of tkTrue: result = trueNode()
  of tkFalse: result = falseNode()
  of tkFloat: result = floatNode(token.floatVal)
  of tkString: result = stringNode(token.stringVal)
  of tkIdent: result = identNode(token.ident)
  of tkOperator:
    let
      op = identNode(token.operator).lineInfoFrom(token)
      expr =
        if token.operator == "@":
          l.parsePrefix(l.next())
        else:
          l.parseExpr(pathPrecedence - 1)
    result = nkPrefix.tree(op, expr).lineInfoFrom(op)
  of tkDot:
    let name = l.expect(tkIdent, peXExpected % "identifier")
    let member = identNode(name).lineInfoFrom(token)
    result = nkMember.tree(member)
  of tkLParen:
    result = nkParen.tree(l.parseExpr())
    discard l.expect(tkRParen, peTokenMissing % ")")
  of tkBlock: result = l.parseBlockExprOrStmt(token, isStmt = false)
  of tkIf: result = l.parseIf(token, isStmt = false)
  of tkProc: result = l.parseProc(token, anonymous = true)
  else: l.error(token, peUnexpectedToken % $token)

  result.lineInfoFrom(token)

proc parseInfix(l: var Lexer, left: Node, token: Token): Node =
  ## Parses an infix expression.

  case token.kind
  of tkOperator:
    let op = identNode(token.operator).lineInfoFrom(token)
    result = nkInfix.tree(op, left, l.parseExpr(token.precedence))
  of tkDot:
    result = nkDot.tree(left, l.parseExpr(pathPrecedence))
  of tkLParen:
    result = nkCall.tree(left)
    l.parseCommaSep(result.sons, tkRParen):
      l.parseExpr()
  of tkLBrace:
    result = nkConstr.tree(left)
    l.parseCommaSep(result.sons, tkRBrace):
      let
        fieldName = l.expect(tkIdent, peXExpected % "field name")
        field = identNode(fieldName)
      l.expectOperator("=", peXExpected % "'='")
      nkFieldVal.tree(field, l.parseExpr()).lineInfoFrom(fieldName)
  else: l.error(token, peUnexpectedToken % $token)

  result.lineInfoFrom(token)

proc precedence(token: Token): int =
  ## Returns the precedence for the given token.

  case token.kind
  of tkOperator: token.precedence
  of tkLParen, tkLBrace, tkDot: pathPrecedence
  else: -10

proc parseExpr(l: var Lexer, precedence = -1): Node =
  ## Parses an expression.

  var token = l.next()
  let
    indentLevel = token.indentLevel
    line = token.line

  result = l.parsePrefix(token)
  while precedence < precedence(l.peek()):

    # check indent level
    let t = l.peek()
    if t.line > line and t.indentLevel <= indentLevel:
      break

    token = l.next()
    if token.kind == tkEof:
      break
    result = l.parseInfix(result, token)

proc parseVar(l: var Lexer): Node =
  ## Parses a variable declaration.

  let
    varToken = l.next()  # always tkVar (see parseStmt)
    name = l.expect(tkIdent, peXExpected % "variable name")
    nameNode = identNode(name)
    names = nkVarList.tree(nameNode).lineInfoFrom(nameNode)
  l.expectOperator("=", peXExpected % "'='")
  let value = l.parseExpr()
  result = nkVar.tree(names, value).lineInfoFrom(varToken)

proc parseWhile(l: var Lexer): Node =
  ## Parses a while loop.

  let
    whileToken = l.next()  # always tkWhile (see parseStmt)
    condition = l.parseExpr()
  l.skip(tkSemi)

  var loop = nkStmtList.tree().lineInfoFrom(l.peek())
  l.parseBlock(loop.sons, whileToken.indentLevel)

  result = nkWhile.tree(condition, loop).lineInfoFrom(whileToken)

proc parseFor(l: var Lexer): Node =
  ## Parses a for-in loop.

  let
    forToken = l.next()  # always tkFor (see parseStmt)
    forVarName = l.expect(tkIdent, peXExpected % "loop variable")
  discard l.expect(tkIn, peXExpected % "'in'")
  let iter = l.parseExpr()
  l.skip(tkSemi)

  var loop = nkStmtList.tree().lineInfoFrom(l.peek())
  l.parseBlock(loop.sons, forToken.indentLevel)

  let
    forVar = identNode(forVarName)
    varList = nkVarList.tree(forVar).lineInfoFrom(forVar)
  result = nkFor.tree(varList, iter, loop).lineInfoFrom(forToken)

proc parseBreak(l: var Lexer): Node =
  ## Parses a break statement.

  let breakToken = l.next()  # always tkBreak (see parseStmt)
  result = nkBreak.tree.lineInfoFrom(breakToken)

proc parseContinue(l: var Lexer): Node =
  ## Parses a continue statement.

  let continueToken = l.next()  # always tkContinue (see parseStmt)
  result = nkContinue.tree.lineInfoFrom(continueToken)

proc parseReturn(l: var Lexer): Node =
  ## Parses a return statement.

  let returnToken = l.next()  # always tkReturn (see parseStmt)
  result = nkReturn.tree(emptyNode()).lineInfoFrom(returnToken)

  if not l.matchLinebreak():
    result[0] = l.parseExpr()

proc parseImpl(l: var Lexer): Node =
  ## Parses an object implementation block.

  let
    implToken = l.next()  # always tkImpl (see parseStmt)
    objectNameToken = l.expect(tkIdent, peXExpected % "object name")
    objectName = identNode(objectNameToken)

  var body = nkStmtList.tree().lineInfoFrom(implToken)
  l.parseBlock(body.sons, implToken.indentLevel)

  result = nkImpl.tree(objectName, body).lineInfoFrom(implToken)

proc parseObject(l: var Lexer): Node =
  ## Parses an object definition.

  let
    objectToken = l.next()  # always tkObject (see parseStmt)
    nameToken = l.expect(tkIdent, peXExpected % "object name")
    name = identNode(nameToken)

  var parentName = emptyNode().lineInfoFrom(name)
  if l.peekOperator("of"):
    discard l.next()
    let parentNameToken = l.expect(tkIdent, peXExpected % "parent name")
    parentName = identNode(parentNameToken)

  l.expectOperator("=", peXExpected % "'='")

  var fields = nkFieldList.tree().lineInfoFrom(l.peek())
  while true:
    let fieldNameToken = l.expect(tkIdent, peXExpected % "field name")
    fields.add(identNode(fieldNameToken))
    if l.peek().kind == tkComma:
      discard l.next()
      continue
    else:
      break

  result = nkObject.tree(name, parentName, fields).lineInfoFrom(objectToken)

proc parseStmt(l: var Lexer): Node =
  ## Parses a statement.

  case l.peek().kind
  of tkVar: result = l.parseVar()
  of tkBlock: result = l.parseBlockExprOrStmt(l.next(), isStmt = true)
  of tkIf: result = l.parseIf(l.next(), isStmt = true)
  of tkWhile: result = l.parseWhile()
  of tkFor: result = l.parseFor()
  of tkBreak: result = l.parseBreak()
  of tkContinue: result = l.parseContinue()
  of tkProc: result = l.parseProc(l.next(), anonymous = false)
  of tkReturn: result = l.parseReturn()
  of tkObject: result = l.parseObject()
  of tkImpl: result = l.parseImpl()
  else: result = l.parseExpr()

proc parseScript*(l: var Lexer): Node =
  ## Parses a script.

  result = nkStmtList.tree().lineInfoFrom(l.peek())

  while true:
    if l.peek().kind == tkEof:
      break
    result.sons.add(l.parseStmt())
    l.skip(tkSemi)


# tests

when isMainModule:

  var cs = new(CompilerState)
  discard cs.addFilename("invalid filename")
  let filenameId = cs.addFilename("test.tsu")

  template test(name, input: string, parse, check: untyped) =

    echo "\n--- ", name
    try:
      var l {.inject.} = initLexer(cs, filenameId, input)
      let n {.inject.} = `parse`
      `check`
      echo "** AST output:"
      echo n.treeRepr
    except ParseError as e:
      echo "!! Error: ", e.msg

  proc walk(n: Node, callback: proc (n: Node)) =

    callback(n)
    if not n.isNil and n.kind notin LeafNodes:
      for o in n.sons:
        walk(o, callback)

  proc verifyNotNil(n: Node) =

    if n.isNil:
      echo "!! found nil node in AST"

  proc verifyLineInfo(n: Node) =

    n.walk proc (n: Node) =
      if n.lineInfo == (0, 0) or n.filename != filenameId:
        echo "!! missing line info in AST:"
        echo n.treeRepr

  template test(name, input: string, parse: untyped) =

    test(name, input):
      `parse`
    do:
      n.verifyNotNil()
      n.verifyLineInfo()

  # expressions
  test("math", "a = 2 + 2 * 2", l.parseExpr())
  test("members", ".a.b.c + .b", l.parseExpr())
  test("non-sigil prefix", "-a.b.c", l.parseExpr())
  test("sigil prefix", "@a.b.c", l.parseExpr())
  test("call echo", "echo(awd)", l.parseExpr())
  test("call no args", "echo()", l.parseExpr())
  test("call >1 arg", "echo(1, 2, 3)", l.parseExpr())
  test("object constructor", "MyObj { a = 1, b = 2 }", l.parseExpr())
  test("if expressions", """
    if a
      _
    elif b
      _
    else
      _
  """, l.parseExpr())

  # statements
  test("script", """
    var x = 1
    var y = 2
    x + y * w
    (a + 1) * 2
  """, l.parseScript())

  test("while", """
    while true
      _
  """, l.parseScript())

  test("for", """
    for i in 1..10
      _
  """, l.parseScript())

  test("procedures", """
    proc long(a, b, c)
      _

    proc no_params
      _

    proc short => _

    proc forward => ...

    var closure = proc
      _
  """, l.parseScript())

  test("objects", """
    object Box = value
    object Vec2 = x, y
  """, l.parseScript())

  test("object impl", """

    object Vec2 = x, y

    impl Vec2
      proc x => .x
      proc y => .y

  """, l.parseScript())
