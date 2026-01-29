// Sources/iMessageMax/Database/QueryBuilder.swift
import Foundation

final class QueryBuilder {
    private var selectCols: [String] = []
    private var fromTable: String = ""
    private var joins: [String] = []
    private var conditions: [(String, [Any])] = []
    private var groupByCols: [String] = []
    private var havingConditions: [(String, [Any])] = []
    private var orderByCols: [String] = []
    private var limitValue: Int?
    private var offsetValue: Int?

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
    func join(_ clause: String) -> QueryBuilder {
        joins.append("JOIN \(clause)")
        return self
    }

    @discardableResult
    func leftJoin(_ clause: String) -> QueryBuilder {
        joins.append("LEFT JOIN \(clause)")
        return self
    }

    @discardableResult
    func `where`(_ condition: String, _ params: Any...) -> QueryBuilder {
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

    @discardableResult
    func offset(_ n: Int) -> QueryBuilder {
        offsetValue = n
        return self
    }

    func build() -> (sql: String, params: [Any]) {
        var parts: [String] = []
        var allParams: [Any] = []

        // SELECT
        parts.append("SELECT \(selectCols.joined(separator: ", "))")

        // FROM
        parts.append("FROM \(fromTable)")

        // JOINs
        parts.append(contentsOf: joins)

        // WHERE
        if !conditions.isEmpty {
            let whereClauses = conditions.map { $0.0 }
            parts.append("WHERE \(whereClauses.joined(separator: " AND "))")
            for (_, params) in conditions {
                allParams.append(contentsOf: params)
            }
        }

        // GROUP BY
        if !groupByCols.isEmpty {
            parts.append("GROUP BY \(groupByCols.joined(separator: ", "))")
        }

        // HAVING
        if !havingConditions.isEmpty {
            let havingClauses = havingConditions.map { $0.0 }
            parts.append("HAVING \(havingClauses.joined(separator: " AND "))")
            for (_, params) in havingConditions {
                allParams.append(contentsOf: params)
            }
        }

        // ORDER BY
        if !orderByCols.isEmpty {
            parts.append("ORDER BY \(orderByCols.joined(separator: ", "))")
        }

        // LIMIT
        if let limit = limitValue {
            parts.append("LIMIT \(limit)")
        }

        // OFFSET
        if let offset = offsetValue {
            parts.append("OFFSET \(offset)")
        }

        return (parts.joined(separator: "\n"), allParams)
    }

    // MARK: - Utility

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
}
