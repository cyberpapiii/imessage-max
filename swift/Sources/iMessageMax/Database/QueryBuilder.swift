// Sources/iMessageMax/Database/QueryBuilder.swift
import Foundation

final class QueryBuilder {
    private var selectCols: [String] = []
    private var fromTable: String = ""
    private var joins: [(String, [Any])] = []
    private var conditions: [(String, [Any])] = []
    private var groupByCols: [String] = []
    private var havingConditions: [(String, [Any])] = []
    private var orderByCols: [String] = []
    private var limitValue: Int?

    @discardableResult
    func select(_ columns: String...) -> QueryBuilder {
        selectCols.append(contentsOf: columns)
        return self
    }

    @discardableResult
    func from(_ table: String) -> QueryBuilder {
        fromTable = table
        return self
    }

    @discardableResult
    func join(_ clause: String, _ params: Any...) -> QueryBuilder {
        join(clause, params: params)
    }

    /// Array form of `join`, for callers that build the join's bindings
    /// conditionally and so cannot spell them out as variadic arguments.
    @discardableResult
    func join(_ clause: String, params: [Any]) -> QueryBuilder {
        joins.append(("JOIN \(clause)", params))
        return self
    }

    @discardableResult
    func leftJoin(_ clause: String, _ params: Any...) -> QueryBuilder {
        joins.append(("LEFT JOIN \(clause)", params))
        return self
    }

    @discardableResult
    func `where`(_ condition: String, _ params: Any...) -> QueryBuilder {
        `where`(condition, params: params)
    }

    /// Array form of `where`, for callers that build bindings in a loop
    /// and so cannot spell them out as variadic arguments.
    @discardableResult
    func `where`(_ condition: String, params: [Any]) -> QueryBuilder {
        conditions.append((condition, params))
        return self
    }

    @discardableResult
    func groupBy(_ columns: String...) -> QueryBuilder {
        groupByCols.append(contentsOf: columns)
        return self
    }

    @discardableResult
    func having(_ condition: String, _ params: Any...) -> QueryBuilder {
        havingConditions.append((condition, params))
        return self
    }

    @discardableResult
    func orderBy(_ columns: String...) -> QueryBuilder {
        orderByCols.append(contentsOf: columns)
        return self
    }

    @discardableResult
    func limit(_ n: Int) -> QueryBuilder {
        limitValue = n
        return self
    }

    func build() -> (sql: String, params: [Any]) {
        var parts: [String] = []
        var allParams: [Any] = []

        parts.append("SELECT \(selectCols.joined(separator: ", "))")
        parts.append("FROM \(fromTable)")
        // Join params bind before WHERE params: a join clause may carry a
        // parameterized subquery, and SQLite binds by position in SQL order.
        for (clause, params) in joins {
            parts.append(clause)
            allParams.append(contentsOf: params)
        }

        if !conditions.isEmpty {
            let whereClauses = conditions.map { $0.0 }
            parts.append("WHERE \(whereClauses.joined(separator: " AND "))")
            for (_, params) in conditions {
                allParams.append(contentsOf: params)
            }
        }

        if !groupByCols.isEmpty {
            parts.append("GROUP BY \(groupByCols.joined(separator: ", "))")
        }

        if !havingConditions.isEmpty {
            let havingClauses = havingConditions.map { $0.0 }
            parts.append("HAVING \(havingClauses.joined(separator: " AND "))")
            for (_, params) in havingConditions {
                allParams.append(contentsOf: params)
            }
        }

        if !orderByCols.isEmpty {
            parts.append("ORDER BY \(orderByCols.joined(separator: ", "))")
        }

        if let limit = limitValue {
            parts.append("LIMIT \(limit)")
        }

        return (parts.joined(separator: "\n"), allParams)
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
}
