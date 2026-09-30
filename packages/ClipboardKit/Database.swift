import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` no llega a Swift desde el header de C: es una macro que
/// castea -1 a un puntero a función. Sin ella, SQLite se queda con el puntero
/// del buffer de Swift en vez de copiar el contenido, y lee memoria liberada.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    public var description: String {
        switch self {
        case .open(let message): "No se pudo abrir la base de datos: \(message)"
        case .prepare(let message, let sql): "Error preparando SQL: \(message) — \(sql)"
        case .step(let message, let sql): "Error ejecutando SQL: \(message) — \(sql)"
        }
    }
}

/// Valor que puede enlazarse a un parámetro de una sentencia.
public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
    public static func optionalText(_ value: String?) -> SQLValue {
        value.map { .text($0) } ?? .null
    }
    public static func optionalInteger(_ value: Int?) -> SQLValue {
        value.map { .integer(Int64($0)) } ?? .null
    }
}

/// Fila materializada. Se copia fuera de la sentencia antes de avanzar, así el
/// consumidor nunca depende del ciclo de vida del statement.
public struct Row: Sendable {
    private let values: [String: SQLValue]

    init(values: [String: SQLValue]) { self.values = values }

    public func int(_ column: String) -> Int64? {
        if case .integer(let value) = values[column] { return value }
        return nil
    }
    public func double(_ column: String) -> Double? {
        if case .real(let value) = values[column] { return value }
        if case .integer(let value) = values[column] { return Double(value) }
        return nil
    }
    public func string(_ column: String) -> String? {
        if case .text(let value) = values[column] { return value }
        return nil
    }
    public func data(_ column: String) -> Data? {
        if case .blob(let value) = values[column] { return value }
        return nil
    }
    public func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }
}

/// Envoltorio mínimo sobre la SQLite del sistema.
///
/// Deliberadamente sin GRDB ni ningún ORM: la app no necesita más que esto, y
/// una dependencia externa en el camino de datos significa resolución de red al
/// compilar, superficie que auditar antes de notarizar y una capa entre yo y el
/// `CREATE VIRTUAL TABLE ... USING fts5`, que es justo donde está el
/// rendimiento. SQLite viene con el sistema; el coste de este fichero es menor
/// que el de mantener la dependencia.
public final class Database {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "desconocido"
            sqlite3_close_v2(handle)
            throw DatabaseError.open(message)
        }

        // WAL: lecturas concurrentes con la escritura del monitor sin bloqueos.
        // NORMAL en vez de FULL porque el peor caso de un crash es perder el
        // último item copiado, no corrupción — un intercambio correcto aquí.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA busy_timeout = 5000;")
    }

    deinit { sqlite3_close_v2(handle) }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "desconocido"
    }

    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorPointer)
            throw DatabaseError.step(message, sql: sql)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int64 {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError.step(errorMessage, sql: sql)
        }
        return sqlite3_last_insert_rowid(handle)
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(statement, Int32(index))))
        }

        var rows: [Row] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw DatabaseError.step(errorMessage, sql: sql)
            }

            var values: [String: SQLValue] = [:]
            for index in 0..<columnCount {
                let column = Int32(index)
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    values[names[index]] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT:
                    values[names[index]] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    if let pointer = sqlite3_column_text(statement, column) {
                        values[names[index]] = .text(String(cString: pointer))
                    }
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, column))
                    if let pointer = sqlite3_column_blob(statement, column), length > 0 {
                        values[names[index]] = .blob(Data(bytes: pointer, count: length))
                    } else {
                        values[names[index]] = .blob(Data())
                    }
                default:
                    values[names[index]] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }


    /// Ejecuta en transacción; revierte ante cualquier error lanzado.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = errorMessage
            sqlite3_finalize(statement)
            throw DatabaseError.prepare(message, sql: sql)
        }

        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let number):
                sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                sqlite3_bind_double(statement, index, number)
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, transient)
            case .blob(let data):
                if data.isEmpty {
                    sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    _ = data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), transient)
                    }
                }
            }
        }
        return statement
    }
}

