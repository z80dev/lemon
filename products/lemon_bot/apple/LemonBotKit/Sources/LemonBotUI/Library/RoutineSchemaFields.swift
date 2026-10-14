import SwiftUI
import LemonBotKit

// This is an editor for the server's registered event filter schema, not a raw JSON resource screen.
struct RoutineSchemaFields: View {
    let schema: JSONObject
    @Binding var values: JSONObject
    private var properties: JSONObject { schema["properties"]?.objectValue ?? [:] }
    private var required: Set<String> { Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []) }
    var body: some View {
        ForEach(properties.keys.sorted(), id: \.self) { key in
            if let property = properties[key]?.objectValue {
                VStack(alignment: .leading) {
                    Text("\(key)\(required.contains(key) ? " · required" : " · optional")").font(.headline)
                    if let description = property["description"]?.stringValue { Text(description).font(.caption) }
                    if !required.contains(key) {
                        Toggle("Set \(key)", isOn: Binding(get: { values[key] != nil }, set: { if $0 { values[key] = Self.defaultValue(property) } else { values.removeValue(forKey: key) } }))
                    }
                    if required.contains(key) || values[key] != nil { AnyView(field(key: key, property: property)) }
                }
            }
        }
    }
    @ViewBuilder private func field(key: String, property: JSONObject) -> some View {
        if let choices = property["enum"]?.arrayValue {
            Picker(key, selection: Binding(get: { values[key] ?? .null }, set: { values[key] = $0 })) {
                Text("Select \(key)").tag(JSONValue.null)
                ForEach(Array(choices.enumerated()), id: \.offset) { _, value in Text(Self.label(value)).tag(value) }
            }
        } else {
            switch property["type"]?.stringValue {
            case "boolean":
                Toggle(key, isOn: Binding(get: { values[key]?.boolValue ?? false }, set: { values[key] = .bool($0) })).onAppear { if required.contains(key), values[key] == nil { values[key] = .bool(false) } }
            case "integer", "number":
                TextField(key, text: Binding(get: { values[key].map(Self.label) ?? "" }, set: { if let number = Double($0), number.isFinite { values[key] = .number(number) } else { values.removeValue(forKey: key) } }))
                if let minimum = property["minimum"] { Text("Minimum: \(Self.label(minimum))").font(.caption) }
                if let maximum = property["maximum"] { Text("Maximum: \(Self.label(maximum))").font(.caption) }
            case "object":
                RoutineSchemaFields(schema: property, values: Binding(get: { values[key]?.objectValue ?? [:] }, set: { values[key] = .object($0) }))
            case "array":
                if let item = property["items"]?.objectValue, let choices = item["enum"]?.arrayValue {
                    ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                        Toggle(Self.label(choice), isOn: Binding(get: { values[key]?.arrayValue?.contains(choice) ?? false }, set: { enabled in
                            var selected = values[key]?.arrayValue ?? []
                            if enabled { if !selected.contains(choice) { selected.append(choice) } } else { selected.removeAll { $0 == choice } }
                            values[key] = .array(selected)
                        }))
                    }
                } else {
                    TextField("\(key) (one value per line)", text: Binding(get: { values[key]?.arrayValue?.map(Self.label).joined(separator: "\n") ?? "" }, set: { text in
                        let itemType = property["items"]?.objectValue?["type"]?.stringValue ?? "string"
                        let entries = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                        values[key] = .array(entries.map { entry in
                            if ["number", "integer"].contains(itemType), let number = Double(entry) { return .number(number) }
                            if itemType == "boolean", ["true", "false"].contains(entry) { return .bool(entry == "true") }
                            return .string(entry)
                        })
                    }), axis: .vertical)
                }
            default:
                TextField(key, text: Binding(get: { values[key]?.stringValue ?? "" }, set: { values[key] = .string($0) }))
            }
        }
    }
    private static func defaultValue(_ property: JSONObject) -> JSONValue {
        if let value = property["default"] { return value }
        switch property["type"]?.stringValue { case "object": return .object([:]); case "array": return .array([]); case "boolean": return .bool(false); case "number", "integer": return .number(0); default: return .string("") }
    }
    private static func label(_ value: JSONValue) -> String {
        switch value { case .string(let value): return value; case .number(let value): return value.rounded() == value ? String(format: "%.0f", value) : String(value); case .bool(let value): return value ? "true" : "false"; case .null: return "Unset"; default: return "Structured value" }
    }
    static func validate(_ object: JSONObject, schema: JSONObject) throws { try validateValue(.object(object), schema: schema, path: "filters") }
    private static func validateValue(_ value: JSONValue, schema: JSONObject, path: String) throws {
        func invalid(_ reason: String) throws { throw RoutineFormError.invalid("\(path): \(reason)") }
        if let choices = schema["enum"]?.arrayValue, !choices.contains(value) { try invalid("choose one of the registered values") }
        if let constant = schema["const"], constant != value { try invalid("does not match registered constant") }
        let type = schema["type"]?.stringValue
        switch value {
        case .object(let object):
            if let type, type != "object" { try invalid("expected \(type)") }
            let properties = schema["properties"]?.objectValue ?? [:]
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            for key in required where object[key] == nil { try invalid("\(key) is required") }
            for (key, value) in object {
                guard let property = properties[key]?.objectValue else { if schema["additionalProperties"]?.boolValue == false { try invalid("unregistered field \(key)") }; continue }
                try validateValue(value, schema: property, path: path + "." + key)
            }
        case .array(let array):
            if let type, type != "array" { try invalid("expected \(type)") }
            if let min = schema["minItems"]?.intValue, array.count < min { try invalid("at least \(min) items required") }
            if let max = schema["maxItems"]?.intValue, array.count > max { try invalid("at most \(max) items allowed") }
            if schema["uniqueItems"]?.boolValue == true && Set(array).count != array.count { try invalid("duplicate items are not allowed") }
            if let itemSchema = schema["items"]?.objectValue { for (index, item) in array.enumerated() { try validateValue(item, schema: itemSchema, path: "\(path)[\(index)]") } }
        case .string(let text):
            if let type, type != "string" { try invalid("expected \(type)") }
            if let min = schema["minLength"]?.intValue, text.count < min { try invalid("at least \(min) characters required") }
            if let max = schema["maxLength"]?.intValue, text.count > max { try invalid("at most \(max) characters allowed") }
            if let pattern = schema["pattern"]?.stringValue, text.range(of: pattern, options: .regularExpression) == nil { try invalid("does not match the registered pattern") }
        case .number(let number):
            if let type, !["number", "integer"].contains(type) { try invalid("expected \(type)") }
            if !number.isFinite || (type == "integer" && number.rounded() != number) { try invalid("finite \(type ?? "number") required") }
            if case .number(let min)? = schema["minimum"], number < min { try invalid("minimum is \(min)") }
            if case .number(let max)? = schema["maximum"], number > max { try invalid("maximum is \(max)") }
            if case .number(let min)? = schema["exclusiveMinimum"], number <= min { try invalid("must exceed \(min)") }
            if case .number(let max)? = schema["exclusiveMaximum"], number >= max { try invalid("must be less than \(max)") }
        case .bool: if let type, type != "boolean" { try invalid("expected \(type)") }
        case .null: if type != "null" { try invalid("value required") }
        }
        // Backend remains authoritative for the complete JSON Schema contract and ingress matching.
    }
}
