import Foundation
import SQLite3
import CryptoKit
import XCTest

/// Read-only physical sample journal/DB inspection. Exports metadata only, never decrypted text or keys.
final class ArchiveDeviceEvidenceTests: XCTestCase {
    func testExportPersistedArchiveMetadata() throws {
        let fm=FileManager.default
        let container=try XCTUnwrap(fm.containerURL(forSecurityApplicationGroupIdentifier:"group.live.sub2s.uhm"))
        var journals=[[String:Any]]();var databases=[[String:Any]]()
        let archiveRoot=container.appendingPathComponent("MLSArchive")
        for namespace in try fm.contentsOfDirectory(at:archiveRoot,includingPropertiesForKeys:nil) {
            let path=namespace.appendingPathComponent("journal.db")
            guard fm.fileExists(atPath:path.path) else {continue}
            let rows=try query(path,"SELECT cid,generation,epoch,kind,status,payload,last_error,retries,created_at FROM recovery_work WHERE kind IN ('restore','restore_epoch','restore_census') ORDER BY cid,generation,kind,epoch")
            let records=try rows.map { row -> [String:Any] in
                var out=row
                if let payload=out.removeValue(forKey:"payload") as? Data {
                    out["progress"]=try JSONSerialization.jsonObject(with:payload)
                }
                return out
            }
            journals.append(["namespace":namespace.lastPathComponent,"records":records])
        }
        let enumerator=try XCTUnwrap(fm.enumerator(at:container,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles]))
        let outcomeIds = Set(journals.flatMap { namespace in
            (namespace["records"] as? [[String: Any]] ?? []).flatMap { row in
                let progress = row["progress"] as? [String: Any]
                return Array((progress?["outcomes"] as? [String: String] ?? [:]).keys)
            }
        })
        let fingerprintIds = Array(outcomeIds.sorted().prefix(5000))
        var inspected=0
        while let file=enumerator.nextObject() as? URL {
            if file.path.contains("/MLSArchive/") || file.path.contains("/mls/") { enumerator.skipDescendants();continue }
            guard ["sqlite","db"].contains(file.pathExtension), inspected<100 else {continue}
            inspected+=1
            let tables=(try? query(file,"SELECT name FROM sqlite_master WHERE type='table'")) ?? []
            guard tables.contains(where:{$0["name"] as? String == "ZMESSAGEDECRYPTDTO"}) else {continue}
            let records=try query(file,"SELECT d.ZMESSAGEID AS message_id,d.ZCIPHERTEXTHASH AS saved_hash,d.ZATTACHMENTSDATA AS metadata,m.ZCID AS cid,m.ZMLSEPOCH AS epoch,m.ZENCRYPTEDDATA AS ciphertext,m.ZDELETEDAT AS deleted_at,m.ZTYPE AS type,CASE WHEN m.ZFORWARDCID IS NULL OR m.ZFORWARDCID='' THEN 0 ELSE 1 END AS stored_forward_field_present FROM ZMESSAGEDECRYPTDTO d LEFT JOIN ZMESSAGEDTO m ON m.Z_PK=d.ZMESSAGE")
            let sanitized=records.map { row -> [String:Any] in
                var out=row
                if let cipher=out.removeValue(forKey:"ciphertext") as? Data {out["ciphertext_sha256"]=hex(Data(SHA256.hash(data:cipher)))}
                if let saved=out.removeValue(forKey:"saved_hash") as? Data {out["saved_ciphertext_sha256"]=hex(saved)}
                if let bytes=out.removeValue(forKey:"metadata") as? Data,
                   let metadata=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] {
                    out["cache_version"]=metadata["version"]
                    if let auth=metadata["authenticatedMetadata"] as? [String:Any] {out["authenticated_metadata"]=auth}
                    let manifests=metadata["e2ee"] as? [[String:Any]] ?? []
                    out["manifest_ids"]=manifests.compactMap {$0["attachment_id"] as? String}
                    out["manifest_count"]=manifests.count
                    out["legacy_attachment_count"]=(metadata["legacy"] as? [Any])?.count ?? 0
                }
                return out
            }
            var fingerprints = [[String: Any]]()
            for start in stride(from: 0, to: fingerprintIds.count, by: 500) {
                let ids = Array(fingerprintIds[start..<min(start+500, fingerprintIds.count)])
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let rows = try query(file, "SELECT ZID AS message_id,ZCID AS cid,ZMLSEPOCH AS epoch,ZENCRYPTEDDATA AS ciphertext FROM ZMESSAGEDTO WHERE ZID IN (\(placeholders))", parameters: ids)
                for var row in rows {
                    if let cipher = row.removeValue(forKey: "ciphertext") as? Data {
                        row["ciphertext_sha256"] = hex(Data(SHA256.hash(data: cipher)))
                        row["ciphertext_bytes"] = cipher.count
                    }
                    fingerprints.append(row)
                }
            }
            databases.append(["relative_path":file.path.replacingOccurrences(of:container.path+"/",with:""),"records":sanitized,
                "outcome_ciphertext_fingerprints": fingerprints])
        }
        XCTAssertFalse(journals.isEmpty)
        let documents=try fm.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        let directory=documents.appendingPathComponent("archive-device-evidence")
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        let output:[String:Any]=["journals":journals,"databases":databases,"inspected_db_files":inspected,
            "fingerprint_scope_distinct_outcomes": outcomeIds.count, "fingerprint_scope_truncated": outcomeIds.count > 5000]
        try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("metadata.json"),options:.atomic)
        print("apin_device_evidence journals=\(journals.count) databases=\(databases.count)")
    }
    private func hex(_ bytes:Data)->String {bytes.map {String(format:"%02x",$0)}.joined()}
    private func query(_ url:URL,_ sql:String, parameters: [String] = [])throws->[[String:Any]] {
        var pointer:OpaquePointer?
        guard sqlite3_open_v2(url.path,&pointer,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK,let db=pointer else {throw NSError(domain:"ArchiveEvidence",code:1)}
        defer {sqlite3_close(db)}
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK,let statement else {throw NSError(domain:"ArchiveEvidence",code:2)}
        defer {sqlite3_finalize(statement)}
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in parameters.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(index+1), $0, -1, transient) }
            guard result == SQLITE_OK else { throw NSError(domain: "ArchiveEvidence", code: 4) }
        }
        var rows=[[String:Any]]();var result:Int32
        repeat {
            result=sqlite3_step(statement)
            if result==SQLITE_ROW {
                var row=[String:Any]()
                for index in 0..<sqlite3_column_count(statement) {
                    let name=String(cString:sqlite3_column_name(statement,index))
                    switch sqlite3_column_type(statement,index) {
                    case SQLITE_TEXT: if let text=sqlite3_column_text(statement,index){row[name]=String(cString:text)}
                    case SQLITE_INTEGER:row[name]=sqlite3_column_int64(statement,index)
                    case SQLITE_FLOAT:row[name]=sqlite3_column_double(statement,index)
                    case SQLITE_BLOB:if let bytes=sqlite3_column_blob(statement,index){row[name]=Data(bytes:bytes,count:Int(sqlite3_column_bytes(statement,index)))}
                    default:break
                    }
                }
                rows.append(row)
            }
        } while result==SQLITE_ROW
        guard result==SQLITE_DONE else {throw NSError(domain:"ArchiveEvidence",code:3)}
        return rows
    }
}
