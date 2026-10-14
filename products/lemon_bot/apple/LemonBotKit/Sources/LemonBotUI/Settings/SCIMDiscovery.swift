import SwiftUI
import Foundation
import LemonBotKit

private final class SCIMNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct SCIMDiscoveryView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var token = ""
    @State private var config: SCIMServiceProviderConfig?
    @State private var resources: [SCIMResourceType] = []
    @State private var schemas: [SCIMSchema] = []
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Integration scope — not product session authority") {
                SecureField("SCIM integration bearer (not persisted)", text: $token)
                Text("The IdP integration uses this deployment's /v1/scim/v2 base, RFC7643/7644 schemas, application/scim+json, ETag/If-Match and standard SCIMError responses. Product bearer tokens cannot impersonate this integration. Provisioning active=false revokes product access, not host files or external provider accounts.")
                Button("Read authenticated standard discovery") { Task { await control.perform { try await load() } } }.disabled(token.isEmpty || control.busy)
                Button("Clear integration credential") { token = ""; config = nil; resources = []; schemas = [] }
            }
            if let config {
                Section("Observed service provider configuration") {
                    Text("PATCH \(config.patch.supported ? "supported" : "unavailable") · bulk \(config.bulk.supported ? "supported" : "unavailable")")
                    Text("Filter \(config.filter.supported ? "supported" : "unavailable") · max results \(config.filter.maxResults)")
                    Text("Password change \(config.changePassword.supported ? "supported" : "unavailable") · sort \(config.sort.supported ? "supported" : "unavailable") · ETag \(config.etag.supported ? "supported" : "unavailable")")
                    ForEach(Array(config.authenticationSchemes.enumerated()), id: \.offset) { _, scheme in Text("\(scheme.name) · \(scheme.type) · \(scheme.description)") }
                }
            }
            Section("Actual resource types") {
                ForEach(resources, id: \.id) { resource in
                    Text("\(resource.name) · \(resource.endpoint)").font(.headline)
                    Text(resource.schema).textSelection(.enabled)
                    Button("Read exact resource-type detail") { Task { await control.perform {
                        let value: SCIMResourceType = try await read("/ResourceTypes/\(adminPath(resource.id))", as: SCIMResourceType.self)
                        if let index = resources.firstIndex(where: { $0.id == value.id }) { resources[index] = value }
                    } } }
                }
            }
            Section("Actual schemas") {
                ForEach(schemas, id: \.id) { schema in
                    DisclosureGroup(schema.name) {
                        Text(schema.description)
                        ForEach(Array(schema.attributes.enumerated()), id: \.offset) { _, attribute in
                            Text("\(attribute["name"]?.stringValue ?? "unnamed") · \(attribute["type"]?.stringValue ?? "unknown type") · \(attribute["required"]?.boolValue == true ? "required" : "optional") · \(attribute["mutability"]?.stringValue ?? "unspecified mutability")")
                        }
                        Button("Read exact schema detail") { Task { await control.perform {
                            let value: SCIMSchema = try await read("/Schemas/\(adminPath(schema.id))", as: SCIMSchema.self)
                            if let index = schemas.firstIndex(where: { $0.id == value.id }) { schemas[index] = value }
                        } } }
                    }
                }
            }
        }.navigationTitle("SCIM discovery").onDisappear { token = "" }
    }
    private func load() async throws {
        config = try await read("/ServiceProviderConfig", as: SCIMServiceProviderConfig.self)
        let types: SCIMList<SCIMResourceType> = try await read("/ResourceTypes", as: SCIMList<SCIMResourceType>.self)
        resources = types.Resources
        let definitions: SCIMList<SCIMSchema> = try await read("/Schemas", as: SCIMList<SCIMSchema>.self)
        schemas = definitions.Resources
    }
    private func read<T: Decodable>(_ suffix: String, as: T.Type) async throws -> T {
        guard let account = store.account, !token.isEmpty else { throw ClientError.signedOut }
        let base = try HTTPTransport.normalizeBaseURL(account.baseURL)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw ClientError.invalidPath }
        components.percentEncodedPath = base.path + "/scim/v2" + suffix
        guard let url = components.url else { throw ClientError.invalidPath }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/scim+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .ephemeral, delegate: SCIMNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard store.account?.id == account.id else { throw ClientError.accountChanged }
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidFrame }
        guard (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(SCIMError.self, from: data) { throw AdminFormError("\(error.detail)\nSCIM \(error.status) · \(error.scimType ?? "unspecified")") }
            throw ClientError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

struct AuditLogSettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var records: [AuditRecord] = []
    @State private var actor = ""
    @State private var resource = ""
    @State private var from = Date().addingTimeInterval(-7 * 86_400)
    @State private var to = Date()
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Sanitized management metadata — not private transcripts") {
                TextField("Actor ID (optional)", text: $actor); TextField("Resource ID (optional)", text: $resource)
                DatePicker("From", selection: $from); DatePicker("To", selection: $to)
                Button("Read audit range") { Task { await control.perform { try await load() } } }
            }
            Section("Recorded actual outcomes") {
                ForEach(records) { record in
                    VStack(alignment: .leading) {
                        Text("\(record.action) · \(record.outcome)").font(.headline)
                        Text("\(record.actor.displayName) · \(record.actor.kind) · \(record.resourceType) \(record.resourceId)")
                        Text("\(adminDate(Double(record.createdAtMs))) · request \(record.requestId)").textSelection(.enabled)
                    }
                }
            }
        }.navigationTitle("Audit metadata").task { await control.perform { try await load() } }
    }
    private func load() async throws {
        var query = ["fromAtMs": String(Int(from.timeIntervalSince1970 * 1000)), "toAtMs": String(Int(to.timeIntervalSince1970 * 1000))]
        if !actor.isEmpty { query["actorId"] = actor }; if !resource.isEmpty { query["resourceId"] = resource }
        records = try await adminReadAll(store, "/audit", query: query, as: AuditRecord.self)
    }
}
