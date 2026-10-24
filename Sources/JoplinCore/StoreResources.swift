import Foundation
import UniformTypeIdentifiers

public extension Store {
    func resource(id: String) -> Resource? {
        row(.resource, id: id).map(Resource.init(row:))
    }

    func url(for resource: Resource) -> URL {
        resourceDirectory.appendingPathComponent(resource.storageName)
    }

    @discardableResult
    func addResource(fileAt source: URL) throws -> Resource {
        let ext = source.pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        return try addResource(filename: source.lastPathComponent, mime: mime, fileExtension: ext) { dest in
            try FileManager.default.copyItem(at: source, to: dest)
        }
    }

    @discardableResult
    func addResource(data: Data, filename: String, mime: String, fileExtension: String) throws -> Resource {
        try addResource(filename: filename, mime: mime, fileExtension: fileExtension) { dest in
            try data.write(to: dest)
        }
    }

    internal func addResource(filename: String, mime: String, fileExtension: String, write: (URL) throws -> Void) throws -> Resource {
        let id = Store.newId()
        let now = Store.now()
        let storage = fileExtension.isEmpty ? id : "\(id).\(fileExtension)"
        let dest = resourceDirectory.appendingPathComponent(storage)
        try write(dest)
        let size = Int64((try FileManager.default.attributesOfItem(atPath: dest.path) as NSDictionary).fileSize())
        try upsert(.resource, [
            "id": id, "title": filename, "filename": filename, "mime": mime, "file_extension": fileExtension, "size": size,
            "created_time": now, "updated_time": now, "user_created_time": now, "user_updated_time": now, "blob_updated_time": now,
        ])
        return resource(id: id)!
    }
}
