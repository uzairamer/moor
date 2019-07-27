part of 'parser.dart';

mixin CrudParser on ParserBase {
  @override
  SelectStatement select() {
    if (!_match(const [TokenType.select])) return null;
    final selectToken = _previous;

    var distinct = false;
    if (_matchOne(TokenType.distinct)) {
      distinct = true;
    } else if (_matchOne(TokenType.all)) {
      distinct = false;
    }

    final resultColumns = <ResultColumn>[];
    do {
      resultColumns.add(_resultColumn());
    } while (_match(const [TokenType.comma]));

    final from = _from();

    final where = _where();
    final groupBy = _groupBy();
    final orderBy = _orderBy();
    final limit = _limit();

    return SelectStatement(
      distinct: distinct,
      columns: resultColumns,
      from: from,
      where: where,
      groupBy: groupBy,
      orderBy: orderBy,
      limit: limit,
    )..setSpan(selectToken, _previous);
  }

  /// Parses a [ResultColumn] or throws if none is found.
  /// https://www.sqlite.org/syntax/result-column.html
  ResultColumn _resultColumn() {
    if (_match(const [TokenType.star])) {
      return StarResultColumn(null)..setSpan(_previous, _previous);
    }

    final positionBefore = _current;

    if (_match(const [TokenType.identifier])) {
      // two options. the identifier could be followed by ".*", in which case
      // we have a star result column. If it's followed by anything else, it can
      // still refer to a column in a table as part of a expression result column
      final identifier = _previous;

      if (_match(const [TokenType.dot]) && _match(const [TokenType.star])) {
        return StarResultColumn((identifier as IdentifierToken).identifier)
          ..setSpan(identifier, _previous);
      }

      // not a star result column. go back and parse the expression.
      // todo this is a bit unorthodox. is there a better way to parse the
      // expression from before?
      _current = positionBefore;
    }

    final tokenBefore = _peek;

    final expr = expression();
    final as = _as();

    return ExpressionResultColumn(expression: expr, as: as?.identifier)
      ..setSpan(tokenBefore, _previous);
  }

  /// Returns an identifier followed after an optional "AS" token in sql.
  /// Returns null if there is
  IdentifierToken _as() {
    if (_match(const [TokenType.as])) {
      return _consume(TokenType.identifier, 'Expected an identifier')
          as IdentifierToken;
    } else if (_match(const [TokenType.identifier])) {
      return _previous as IdentifierToken;
    } else {
      return null;
    }
  }

  List<Queryable> _from() {
    if (!_matchOne(TokenType.from)) return [];

    // Can either be a list of <TableOrSubquery> or a join. Joins also start
    // with a TableOrSubquery, so let's first parse that.
    final start = _tableOrSubquery();
    // parse join, if it is one
    final join = _joinClause(start);
    if (join != null) {
      return [join];
    }

    // not a join. Keep the TableOrSubqueries coming!
    final queries = [start];
    while (_matchOne(TokenType.comma)) {
      queries.add(_tableOrSubquery());
    }

    return queries;
  }

  TableOrSubquery _tableOrSubquery() {
    //  this is what we're parsing: https://www.sqlite.org/syntax/table-or-subquery.html
    // we currently only support regular tables and nested selects
    final tableRef = _tableReference();
    if (tableRef != null) {
      return tableRef;
    } else if (_matchOne(TokenType.leftParen)) {
      final innerStmt = select();
      _consume(TokenType.rightParen,
          'Expected a right bracket to terminate the inner select');

      final alias = _as();
      return SelectStatementAsSource(
          statement: innerStmt, as: alias?.identifier);
    }

    _error('Expected a table name or a nested select statement');
  }

  TableReference _tableReference() {
    if (_matchOne(TokenType.identifier)) {
      // ignore the schema name, it's not supported. Besides that, we're on the
      // first branch in the diagram here
      final tableName = (_previous as IdentifierToken).identifier;
      final alias = _as();
      return TableReference(tableName, alias?.identifier);
    }
    return null;
  }

  JoinClause _joinClause(TableOrSubquery start) {
    var operator = _parseJoinOperatorNoComma();
    if (operator == null) {
      return null;
    }

    final joins = <Join>[];

    while (operator != null) {
      final subquery = _tableOrSubquery();
      final constraint = _joinConstraint();
      JoinOperator resolvedOperator;
      if (operator.contains(TokenType.left)) {
        resolvedOperator = operator.contains(TokenType.outer)
            ? JoinOperator.leftOuter
            : JoinOperator.left;
      } else if (operator.contains(TokenType.inner)) {
        resolvedOperator = JoinOperator.inner;
      } else if (operator.contains(TokenType.cross)) {
        resolvedOperator = JoinOperator.cross;
      } else if (operator.contains(TokenType.comma)) {
        resolvedOperator = JoinOperator.comma;
      } else {
        resolvedOperator = JoinOperator.none;
      }

      joins.add(Join(
        natural: operator.contains(TokenType.natural),
        operator: resolvedOperator,
        query: subquery,
        constraint: constraint,
      ));

      // parse the next operator, if there is more than one join
      if (_matchOne(TokenType.comma)) {
        operator = [TokenType.comma];
      } else {
        operator = _parseJoinOperatorNoComma();
      }
    }

    return JoinClause(primary: start, joins: joins);
  }

  /// Parses https://www.sqlite.org/syntax/join-operator.html, minus the comma.
  List<TokenType> _parseJoinOperatorNoComma() {
    if (_match(_startOperators)) {
      final operators = [_previous.type];

      if (_previous.type == TokenType.join) {
        // just join, without any specific operators
        return operators;
      } else {
        // natural is a prefix, another operator can follow.
        if (_previous.type == TokenType.natural) {
          if (_match([TokenType.left, TokenType.inner, TokenType.cross])) {
            operators.add(_previous.type);
          }
        }
        if (_previous.type == TokenType.left && _matchOne(TokenType.outer)) {
          operators.add(_previous.type);
        }

        _consume(TokenType.join, 'Expected to see a join keyword here');
        return operators;
      }
    }
    return null;
  }

  /// Parses https://www.sqlite.org/syntax/join-constraint.html
  JoinConstraint _joinConstraint() {
    if (_matchOne(TokenType.on)) {
      return OnConstraint(expression: expression());
    } else if (_matchOne(TokenType.using)) {
      _consume(TokenType.leftParen, 'Expected an opening paranthesis');

      final columnNames = <String>[];
      do {
        final identifier =
            _consume(TokenType.identifier, 'Expected a column name');
        columnNames.add((identifier as IdentifierToken).identifier);
      } while (_matchOne(TokenType.comma));

      _consume(TokenType.rightParen, 'Expected an closing paranthesis');

      return UsingConstraint(columnNames: columnNames);
    }
    _error('Expected a constraint with ON or USING');
  }

  /// Parses a where clause if there is one at the current position
  Expression _where() {
    if (_match(const [TokenType.where])) {
      return expression();
    }
    return null;
  }

  GroupBy _groupBy() {
    if (_matchOne(TokenType.group)) {
      _consume(TokenType.by, 'Expected a "BY"');
      final by = <Expression>[];
      Expression having;

      do {
        by.add(expression());
      } while (_matchOne(TokenType.comma));

      if (_matchOne(TokenType.having)) {
        having = expression();
      }

      return GroupBy(by: by, having: having);
    }
    return null;
  }

  OrderBy _orderBy() {
    if (_match(const [TokenType.order])) {
      _consume(TokenType.by, 'Expected "BY" after "ORDER" token');
      final terms = <OrderingTerm>[];
      do {
        terms.add(_orderingTerm());
      } while (_matchOne(TokenType.comma));
      return OrderBy(terms: terms);
    }
    return null;
  }

  OrderingTerm _orderingTerm() {
    final expr = expression();

    return OrderingTerm(expression: expr, orderingMode: _orderingModeOrNull());
  }

  @override
  OrderingMode _orderingModeOrNull() {
    if (_match(const [TokenType.asc, TokenType.desc])) {
      final mode = _previous.type == TokenType.asc
          ? OrderingMode.ascending
          : OrderingMode.descending;
      return mode;
    }
    return null;
  }

  /// Parses a [Limit] clause, or returns null if there is no limit token after
  /// the current position.
  Limit _limit() {
    if (!_matchOne(TokenType.limit)) return null;

    // Unintuitive, it's "$amount OFFSET $offset", but "$offset, $amount"
    // the order changes between the separator tokens.
    final first = expression();

    if (_matchOne(TokenType.comma)) {
      final separator = _previous;
      final count = expression();
      return Limit(count: count, offsetSeparator: separator, offset: first);
    } else if (_matchOne(TokenType.offset)) {
      final separator = _previous;
      final offset = expression();
      return Limit(count: first, offsetSeparator: separator, offset: offset);
    } else {
      return Limit(count: first);
    }
  }

  DeleteStatement _deleteStmt() {
    if (!_matchOne(TokenType.delete)) return null;
    _consume(TokenType.from, 'Expected a FROM here');

    final table = _tableReference();
    Expression where;
    if (table == null) {
      _error('Expected a table reference');
    }

    if (_matchOne(TokenType.where)) {
      where = expression();
    }

    return DeleteStatement(from: table, where: where);
  }

  UpdateStatement _update() {
    if (!_matchOne(TokenType.update)) return null;
    FailureMode failureMode;
    if (_matchOne(TokenType.or)) {
      failureMode = UpdateStatement.failureModeFromToken(_advance().type);
    }

    final table = _tableReference();
    _consume(TokenType.set, 'Expected SET after the table name');

    final set = <SetComponent>[];
    do {
      final columnName =
          _consume(TokenType.identifier, 'Expected a column name to set')
              as IdentifierToken;
      final reference = Reference(columnName: columnName.identifier)
        ..setSpan(columnName, columnName);
      _consume(TokenType.equal, 'Expected = after the column name');
      final expr = expression();

      set.add(SetComponent(column: reference, expression: expr));
    } while (_matchOne(TokenType.comma));

    final where = _where();
    return UpdateStatement(
        or: failureMode, table: table, set: set, where: where);
  }
}
