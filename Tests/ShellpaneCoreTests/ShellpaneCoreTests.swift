import Foundation
import SSHProcess
import Testing
@testable import ShellpaneCore
import TransferKit

func tempDBPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("shellpane-db-\(UUID().uuidString)/shellpane.sqlite").path
}

@Suite struct DatabaseTests {
    @Test func embeddedMigrationMatchesSchemaFile() throws {
        let schema = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("db/schema.sql")
        #expect(try String(contentsOf: schema, encoding: .utf8) == Migrations.v1,
                "Run python3 scripts/embed_migrations.py after editing db/schema.sql")
        let v2 = schema.deletingLastPathComponent().appendingPathComponent("migrations/v2.sql")
        #expect(try String(contentsOf: v2, encoding: .utf8) == Migrations.v2,
                "Run python3 scripts/embed_migrations.py after editing db/migrations/v2.sql")
        let v3 = schema.deletingLastPathComponent().appendingPathComponent("migrations/v3.sql")
        #expect(try String(contentsOf: v3, encoding: .utf8) == Migrations.v3,
                "Run python3 scripts/embed_migrations.py after editing db/migrations/v3.sql")
    }

    @Test func aVersionOneDatabaseUpgradesAndKeepsItsServers() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        do {
            let old = try Database(path: path, migrations: [Migrations.v1])
            #expect(old.schemaVersion == 1)
            // Written the way a version-1 app wrote it: today's store knows columns v1 doesn't have.
            try old.execute("INSERT INTO favorites (id, name, host) VALUES ('w', 'Web', 'example.com')")
        }
        let upgraded = try Database(path: path)
        #expect(upgraded.schemaVersion == Migrations.all.count)
        #expect(try FavoritesStore(database: upgraded).all().map(\.name) == ["Web"])
        #expect(try FavoritesStore(database: upgraded).all().first?.icon == nil)   // servers from before icons: the default
        #expect(try BookmarksStore(database: upgraded).all().isEmpty)
    }

    @Test func createsEverythingAndRecordsTheVersion() throws {
        let db = try Database(path: ":memory:")
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .compactMap { $0["name"]?.string }
        #expect(tables == ["bookmarks", "edit_sessions", "favorite_groups", "favorites", "log_entries", "settings", "synclets", "transfer_jobs"])
        #expect(db.schemaVersion == Migrations.all.count)
        #expect(try db.query("SELECT value FROM settings WHERE key = 'default_conflict_rule'").first?["value"] == .text("\"ask\""))
    }

    @Test func fileIsPrivateAndSurvivesReopen() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        do {
            let store = FavoritesStore(database: try Database(path: path))
            try store.save(Favorite(name: "Web", host: "example.com"))
        }
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
        let reopened = try Database(path: path)
        #expect(reopened.schemaVersion == Migrations.all.count)  // not re-applied
        #expect(try FavoritesStore(database: reopened).all().map(\.name) == ["Web"])
    }

    @Test func foreignKeysAreEnforced() throws {
        let db = try Database(path: ":memory:")
        #expect(throws: DatabaseError.self) {
            try db.execute("INSERT INTO favorites (id, name, host, group_id) VALUES ('f', 'x', 'h', 'no-such-group')")
        }
    }

    @Test func checkConstraintsRejectBadRows() throws {
        let db = try Database(path: ":memory:")
        #expect(throws: DatabaseError.self) {  // no host and no alias
            try db.execute("INSERT INTO favorites (id, name) VALUES ('f', 'x')")
        }
        #expect(throws: DatabaseError.self) {  // two-way sync that deletes orphans is refused
            try db.execute("INSERT INTO synclets (id, name, left_path, right_path, direction, delete_orphans) VALUES ('s','x','/a','/b','both',1)")
        }
        #expect(throws: DatabaseError.self) {
            try db.execute("INSERT INTO favorites (id, name, host, colour) VALUES ('f', 'x', 'h', '#ff0000')")
        }
    }

    @Test func failedTransactionRollsBack() throws {
        let db = try Database(path: ":memory:")
        _ = try? db.transaction {
            try db.execute("INSERT INTO favorite_groups (id, name) VALUES ('g', 'Group')")
            throw DatabaseError(code: 0, message: "boom")
        }
        #expect(try db.query("SELECT * FROM favorite_groups").isEmpty)
    }
}

@Suite struct FavoritesTests {
    @Test func saveLoadUpdateDelete() throws {
        let store = FavoritesStore(database: try Database(path: ":memory:"))
        var f = Favorite(name: "Production", host: "web-1.example.com", port: 2222, username: "deploy",
                         auth: .key, keyPath: "~/.ssh/id_ed25519", initialPath: "/var/www", colour: "green")
        try store.save(f)
        #expect(try store.favorite(id: f.id)?.host == "web-1.example.com")

        f.name = "Production (EU)"
        f.port = nil
        try store.save(f)
        let loaded = try #require(try store.favorite(id: f.id))
        #expect(loaded.name == "Production (EU)")
        #expect(loaded.port == nil)
        #expect(loaded.auth == .key)
        #expect(loaded.colour == "green")
        #expect(try store.all().count == 1)

        try store.delete(id: f.id)
        #expect(try store.all().isEmpty)
    }

    @Test func emptyStringsAreStoredAsNothing() throws {
        let store = FavoritesStore(database: try Database(path: ":memory:"))
        let f = Favorite(name: "  Web  ", host: "h", username: "  ", initialPath: "")
        try store.save(f)
        let loaded = try #require(try store.favorite(id: f.id))
        #expect(loaded.name == "Web")
        #expect(loaded.username == nil)
        #expect(loaded.initialPath == nil)
    }

    @Test func newFavoritesGoLastAndCanBeReordered() throws {
        let store = FavoritesStore(database: try Database(path: ":memory:"))
        let a = Favorite(name: "Zeta", host: "a"), b = Favorite(name: "Alpha", host: "b"), c = Favorite(name: "Mid", host: "c")
        for f in [a, b, c] { try store.save(f) }
        #expect(try store.all().map(\.name) == ["Zeta", "Alpha", "Mid"])  // the order you added them, not A-Z
        try store.move(id: c.id, toIndex: 0)
        #expect(try store.all().map(\.name) == ["Mid", "Zeta", "Alpha"])
    }

    @Test func namesWithQuotesAreJustText() throws {
        let store = FavoritesStore(database: try Database(path: ":memory:"))
        let f = Favorite(name: "Robert'); DROP TABLE favorites;--", host: "h")
        try store.save(f)
        #expect(try store.all().first?.name == "Robert'); DROP TABLE favorites;--")
    }

    @Test func markUsed() throws {
        let store = FavoritesStore(database: try Database(path: ":memory:"))
        let f = Favorite(name: "W", host: "h")
        try store.save(f)
        try store.markUsed(id: f.id, at: Date(timeIntervalSince1970: 1_760_000_000))
        #expect(try store.favorite(id: f.id)?.lastUsedAt == Date(timeIntervalSince1970: 1_760_000_000))
    }

    @Test func deletingAGroupKeepsItsServers() throws {
        let db = try Database(path: ":memory:")
        let store = FavoritesStore(database: db)
        try db.execute("INSERT INTO favorite_groups (id, name) VALUES ('g', 'Clients')")
        let f = Favorite(groupID: "g", name: "W", host: "h")
        try store.save(f)
        try db.execute("DELETE FROM favorite_groups WHERE id = 'g'")
        #expect(try store.favorite(id: f.id)?.groupID == nil)
    }

    @Test func deletingAServerDeletesItsSyncletsButKeepsTransferHistory() throws {
        let db = try Database(path: ":memory:")
        let store = FavoritesStore(database: db)
        let f = Favorite(name: "W", host: "h")
        try store.save(f)
        try db.execute("INSERT INTO synclets (id, name, left_path, right_favorite_id, right_path) VALUES ('s', 'x', '/a', ?, '/b')", [.text(f.id)])
        try db.execute("INSERT INTO transfer_jobs (id, batch_id, kind, src_favorite_id, src_path, dst_path, queue_order) VALUES ('j', 'b', 'download', ?, '/x', '/y', 1)", [.text(f.id)])
        try store.delete(id: f.id)
        #expect(try db.query("SELECT * FROM synclets").isEmpty)
        #expect(try db.query("SELECT src_favorite_id FROM transfer_jobs").first?["src_favorite_id"] == .null)
    }

    @Test func storeRefusesInvalidFavorites() throws {
        let store = FavoritesStore(database: try Database(path: ":memory:"))
        #expect(throws: Favorite.ValidationError.missingServer) { try store.save(Favorite(name: "x")) }
        #expect(throws: Favorite.ValidationError.unsafeServer) { try store.save(Favorite(name: "x", host: "-oProxyCommand=evil")) }
    }
}

@Suite struct ValidationAndTargetTests {
    @Test func validation() {
        #expect(Favorite(name: "", host: "h").validate() == [.missingName])
        #expect(Favorite(name: "x", host: "h", port: 70000).validate() == [.badPort])
        #expect(Favorite(name: "x", host: "h", username: "bad user").validate() == [.unsafeUser])
        #expect(Favorite(name: "x", host: "h", auth: .key).validate() == [.missingKey])
        #expect(Favorite(name: "x", host: "h", auth: .key, keyPath: "/nope").validate(fileExists: { _ in false }) == [.keyNotFound("/nope")])
        #expect(Favorite(name: "x", sshAlias: "prod").validate().isEmpty)
    }

    @Test func aliasWinsAndOverridesPassThrough() {
        let f = Favorite(name: "x", sshAlias: "prod", host: "ignored", port: 2200, username: "root")
        #expect(f.target == SSHTarget(host: "prod", port: 2200, user: "root"))
    }

    @Test func keyOnlyPassedWhenAuthIsKey() {
        #expect(Favorite(name: "x", host: "h", auth: .auto, keyPath: "/k").target.identityFile == nil)
        #expect(Favorite(name: "x", host: "h", auth: .key, keyPath: "/k").target.identityFile == "/k")
    }

    @Test func passwordAuthTurnsOffKeys() {
        #expect(Favorite(name: "x", host: "h", auth: .password).extraSSHOptions.contains("-oPubkeyAuthentication=no"))
        #expect(Favorite(name: "x", host: "h", auth: .auto).extraSSHOptions.isEmpty)
    }
}

@Suite struct CredentialTests {
    let secret = AskpassRequest(prompt: "deploy@h's password: ", hint: "")
    let hostKey = AskpassRequest(prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ", hint: "")

    @Test func savedSecretIsOfferedOnceThenThePersonIsAsked() throws {
        let store = MemorySecretStore()
        try store.setSecret("hunter2", for: "ref", label: "W")
        let ctx = CredentialContext(keychainRef: "ref", label: "W", store: store)
        #expect(ctx.decide(secret) == .answer("hunter2"))
        #expect(ctx.decide(secret) == .askUser)  // ssh asked again: the saved one was wrong
        #expect(ctx.savedSecretWasRejected)
    }

    @Test func hostKeyQuestionsAlwaysGoToThePerson() throws {
        let store = MemorySecretStore()
        try store.setSecret("yes", for: "ref", label: "W")
        #expect(CredentialContext(keychainRef: "ref", label: "W", store: store).decide(hostKey) == .askUser)
    }

    @Test func typedPasswordIsUsedFirstAndSavedOnlyOnSuccess() throws {
        let store = MemorySecretStore()
        let ctx = CredentialContext(keychainRef: "ref", label: "W", store: store, typedSecret: "typed")
        #expect(ctx.decide(secret) == .answer("typed"))
        ctx.rememberAfterSuccess("typed")
        #expect(try store.secret(for: "ref") == nil)  // not yet
        try ctx.connectionSucceeded()
        #expect(try store.secret(for: "ref") == "typed")
    }

    @Test func nothingSavedWithoutAKeychainRef() throws {
        let store = MemorySecretStore()
        let ctx = CredentialContext(keychainRef: nil, label: "W", store: store)
        #expect(ctx.decide(secret) == .askUser)
        ctx.rememberAfterSuccess("x")
        try ctx.connectionSucceeded()
    }

    /// Writes to and deletes from your login keychain, so it only runs when asked:
    ///   SHELLPANE_KEYCHAIN_TESTS=1 swift test --filter keychainRoundTrip
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHELLPANE_KEYCHAIN_TESTS"] == "1"))
    func keychainRoundTrip() throws {
        let store = KeychainStore(service: "app.shellpane.tests")
        let ref = UUID().uuidString
        defer { try? store.deleteSecret(for: ref) }
        #expect(try store.secret(for: ref) == nil)
        try store.setSecret("first", for: ref, label: "Shellpane test")
        #expect(try store.secret(for: ref) == "first")
        try store.setSecret("second ✓", for: ref, label: "Shellpane test")
        #expect(try store.secret(for: ref) == "second ✓")
        try store.deleteSecret(for: ref)
        #expect(try store.secret(for: ref) == nil)
        try store.deleteSecret(for: ref)  // deleting twice is fine
    }
}

@Suite struct SyncletTests {
    @Test func saveLoadEveryOptionAndDelete() throws {
        let db = try Database(path: ":memory:")
        let favorites = FavoritesStore(database: db)
        let server = Favorite(name: "Web", host: "web-1")
        try favorites.save(server)
        var o = SyncOptions()
        o.direction = .rightToLeft
        o.subfolders = false
        o.includeHidden = true
        o.addMissing = false
        o.skipEmptyFolders = true
        o.updateBy = .dateOrSize
        o.deleteOrphans = true
        o.timeOffset = -3600
        o.excludes = ["*.log", "node_modules", "with \"quotes\""]
        let s = Synclet(name: "Site backup", leftFavoriteID: nil, leftPath: "/Users/me/Sites/blog",
                        rightFavoriteID: server.id, rightPath: "/var/www/blog", options: o)
        let store = SyncletsStore(database: db)
        try store.save(s)
        #expect(try store.all() == [s])
        try store.delete(id: s.id)
        #expect(try store.all().isEmpty)
    }

    @Test func refusesTwoWayWithDeletes() throws {
        var o = SyncOptions()
        o.direction = .both
        o.deleteOrphans = true
        let store = SyncletsStore(database: try Database(path: ":memory:"))
        #expect(throws: SyncError.twoWayDelete) {
            try store.save(Synclet(name: "x", leftFavoriteID: nil, leftPath: "/a", rightFavoriteID: nil, rightPath: "/b", options: o))
        }
    }

    @Test func deletingTheServerDeletesItsSynclets() throws {
        let db = try Database(path: ":memory:")
        let favorites = FavoritesStore(database: db)
        let server = Favorite(name: "Web", host: "web-1")
        try favorites.save(server)
        let store = SyncletsStore(database: db)
        try store.save(Synclet(name: "x", leftFavoriteID: nil, leftPath: "/a", rightFavoriteID: server.id, rightPath: "/b", options: SyncOptions()))
        try favorites.delete(id: server.id)
        #expect(try store.all().isEmpty)
    }
}

@Suite struct OperationLogTests {
    @Test func recordsNewestFirstAndKeepsHistoryWhenAServerIsDeleted() throws {
        let db = try Database(path: ":memory:")
        let log = OperationLog(database: db)
        let favorites = FavoritesStore(database: db)
        let server = Favorite(name: "Web", host: "web-1")
        try favorites.save(server)
        log.record(.connect, path: nil, favoriteID: server.id, at: Date(timeIntervalSince1970: 1_700_000_000))
        log.record(.upload, path: "/var/www/index.html", favoriteID: server.id, at: Date(timeIntervalSince1970: 1_700_000_100))
        log.record(.delete, path: "/var/www/old", result: .failed, message: "Permission denied", at: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(try log.recent().map(\.operation) == [.delete, .upload, .connect])
        #expect(try log.recent().first?.result == .failed)
        try favorites.delete(id: server.id)
        let after = try log.recent()
        #expect(after.count == 3)
        #expect(after.allSatisfy { $0.favoriteID == nil })
    }

    @Test func unknownServerIdIsStoredAsNone() throws {
        let log = OperationLog(database: try Database(path: ":memory:"))
        log.record(.connect, path: nil, favoriteID: "not-a-saved-server")
        #expect(try log.recent().first?.favoriteID == nil)
    }

    @Test func pruneDropsOldEntries() throws {
        let log = OperationLog(database: try Database(path: ":memory:"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(.copy, path: "old", at: now.addingTimeInterval(-40 * 86_400))
        log.record(.copy, path: "new", at: now.addingTimeInterval(-1 * 86_400))
        log.prune(olderThanDays: 30, now: now)
        #expect(try log.recent().map(\.path) == ["new"])
    }
}

@Suite struct GroupTests {
    @Test func createRenameMoveDelete() throws {
        let db = try Database(path: ":memory:")
        let groups = GroupsStore(database: db)
        let favorites = FavoritesStore(database: db)
        let web = Favorite(name: "Web", host: "web-1")
        try favorites.save(web)
        let clients = try groups.create("  Clients ")
        let staging = try groups.create("Staging")
        #expect(try groups.all().map(\.name) == ["Clients", "Staging"])  // creation order
        try groups.move(favorite: web.id, to: clients.id)
        #expect(try favorites.favorite(id: web.id)?.groupID == clients.id)
        try groups.rename(clients.id, to: "Client work")
        #expect(try groups.all().first?.name == "Client work")
        try groups.delete(clients.id)
        #expect(try favorites.favorite(id: web.id)?.groupID == nil)        // the server stays, ungrouped
        #expect(try favorites.all().count == 1)
        try groups.move(favorite: web.id, to: staging.id)
        try groups.move(favorite: web.id, to: nil)
        #expect(try favorites.favorite(id: web.id)?.groupID == nil)
    }

    @Test func emptyNamesAreRefused() throws {
        let groups = GroupsStore(database: try Database(path: ":memory:"))
        #expect(throws: Favorite.ValidationError.missingName) { try groups.create("   ") }
    }

    @Test func movingToAMissingGroupIsRefused() throws {
        let db = try Database(path: ":memory:")
        let favorites = FavoritesStore(database: db)
        let web = Favorite(name: "Web", host: "web-1")
        try favorites.save(web)
        #expect(throws: DatabaseError.self) { try GroupsStore(database: db).move(favorite: web.id, to: "nope") }
    }
}

@Suite struct BackupTests {
    func stores(_ db: Database) -> (FavoritesStore, GroupsStore, SyncletsStore) {
        (FavoritesStore(database: db), GroupsStore(database: db), SyncletsStore(database: db))
    }

    @Test func roundTripWithoutSecrets() throws {
        let (fav, grp, syn) = stores(try Database(path: ":memory:"))
        let g = try grp.create("Clients")
        var web = Favorite(name: "Web", host: "web-1.example.com", port: 2222, username: "deploy", auth: .password,
                           keychainRef: "ref-on-this-mac", colour: "green", icon: "cart")
        web.groupID = g.id
        try fav.save(web)
        var o = SyncOptions(); o.excludes = ["*.log"]
        try syn.save(Synclet(name: "Site", leftFavoriteID: nil, leftPath: "/Users/me/site", rightFavoriteID: web.id, rightPath: "/var/www", options: o))
        let data = try BackupIO.export(favorites: fav, groups: grp, synclets: syn)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("ref-on-this-mac"))
        #expect(!json.lowercased().contains("keychain"))

        let (fav2, grp2, syn2) = stores(try Database(path: ":memory:"))
        let r = try BackupIO.importBackup(data, favorites: fav2, groups: grp2, synclets: syn2)
        #expect(r == .init(groups: 1, servers: 1, syncs: 1, skipped: 0))
        let imported = try #require(try fav2.all().first)
        #expect(imported.host == "web-1.example.com" && imported.port == 2222 && imported.auth == .password && imported.colour == "green")
        #expect(imported.icon == "cart")
        #expect(imported.keychainRef != nil && imported.keychainRef != "ref-on-this-mac")   // fresh slot; password asked once
        #expect(imported.groupID == (try grp2.all().first?.id))
        let s = try #require(try syn2.all().first)
        #expect(s.rightFavoriteID == imported.id && s.options.excludes == ["*.log"])
    }

    @Test func importingTwiceAddsNothingNew() throws {
        let (fav, grp, syn) = stores(try Database(path: ":memory:"))
        try fav.save(Favorite(name: "Web", host: "web-1"))
        let data = try BackupIO.export(favorites: fav, groups: grp, synclets: syn)
        let (fav2, grp2, syn2) = stores(try Database(path: ":memory:"))
        _ = try BackupIO.importBackup(data, favorites: fav2, groups: grp2, synclets: syn2)
        let again = try BackupIO.importBackup(data, favorites: fav2, groups: grp2, synclets: syn2)
        #expect(again.servers == 0 && again.skipped == 1)
        #expect(try fav2.all().count == 1)
    }

    @Test func rejectsFilesThatArentBackups() throws {
        let (fav, grp, syn) = stores(try Database(path: ":memory:"))
        #expect(throws: (any Error).self) { try BackupIO.importBackup(Data("{\"format\":\"other\",\"version\":1}".utf8), favorites: fav, groups: grp, synclets: syn) }
        #expect(throws: (any Error).self) { try BackupIO.importBackup(Data("not json".utf8), favorites: fav, groups: grp, synclets: syn) }
    }
}

@Suite struct ServerAppearanceTests {
    @Test func iconAndColourAreSavedAndChanged() throws {
        let store = FavoritesStore(database: try Database(path: ":memory:"))
        var web = Favorite(name: "Web", host: "web-1.example.com", colour: "teal", icon: "globe")
        try store.save(web)
        #expect(try store.favorite(id: web.id)?.icon == "globe")
        #expect(try store.favorite(id: web.id)?.colour == "teal")
        web.icon = "cloud"
        web.colour = "orange"
        try store.save(web)
        let saved = try #require(try store.favorite(id: web.id))
        #expect(saved.icon == "cloud" && saved.colour == "orange")
        web.icon = nil
        try store.save(web)
        #expect(try store.favorite(id: web.id)?.icon == nil)
    }

    @Test func anEmptyUsernameLeavesTheChoiceToSSH() {
        // An empty username once reached ssh as `-l ''` and every login failed.
        #expect(Favorite(name: "W", sshAlias: "web-1", username: "").target.user == nil)
        #expect(Favorite(name: "W", sshAlias: "web-1", username: "  ").target.user == nil)
        #expect(Favorite(name: "W", sshAlias: "web-1", username: "deploy").target.user == "deploy")
    }

    @Test func anIconNameIsShortAndPlain() {
        #expect(Favorite(name: "W", host: "h", icon: "server.rack").validate().isEmpty)
        #expect(!Favorite(name: "W", host: "h", icon: String(repeating: "a", count: 65)).validate().isEmpty)
        #expect(!Favorite(name: "W", host: "h", icon: "../../x").validate().isEmpty)
    }
}

@Suite struct BookmarkTests {
    @Test func foldersOnTheMacAndOnServersKeepTheirOrder() throws {
        let db = try Database(path: ":memory:")
        let web = Favorite(name: "Web", host: "example.com")
        try FavoritesStore(database: db).save(web)
        let store = BookmarksStore(database: db)
        try store.add(place: .local, path: "/Users/me/Sites")
        try store.add(place: .favorite(web.id), path: "/var/www/site")
        try store.add(name: "Logs", place: .sshAlias("db-1"), path: "/var/log")
        let all = try store.all()
        #expect(all.map(\.name) == ["Sites", "site", "Logs"])
        #expect(all.map(\.place) == [.local, .favorite(web.id), .sshAlias("db-1")])
        #expect(all[1].path == "/var/www/site")
    }

    @Test func theSameFolderIsKeptOnce() throws {
        let store = BookmarksStore(database: try Database(path: ":memory:"))
        let a = try store.add(place: .sshAlias("db-1"), path: "/var/log")
        let b = try store.add(place: .sshAlias("db-1"), path: "/var/log")
        #expect(a.id == b.id)
        #expect(try store.all().count == 1)
        try store.add(place: .local, path: "/var/log")   // same path, different place: a different folder
        #expect(try store.all().count == 2)
    }

    @Test func renameAndDelete() throws {
        let store = BookmarksStore(database: try Database(path: ":memory:"))
        let b = try store.add(place: .local, path: "/")
        #expect(b.name == "/")
        try store.rename(b.id, to: "  Root  ")
        #expect(try store.all().first?.name == "Root")
        #expect(throws: (any Error).self) { try store.rename(b.id, to: "   ") }
        try store.delete(b.id)
        #expect(try store.all().isEmpty)
    }

    @Test func deletingAServerRemovesItsFolders() throws {
        let db = try Database(path: ":memory:")
        let favorites = FavoritesStore(database: db)
        let web = Favorite(name: "Web", host: "example.com")
        try favorites.save(web)
        let store = BookmarksStore(database: db)
        try store.add(place: .favorite(web.id), path: "/var/www")
        try store.add(place: .local, path: "/tmp")
        try favorites.delete(id: web.id)
        #expect(try store.all().map(\.path) == ["/tmp"])
    }

    @Test func relativePathsAreRefused() throws {
        let store = BookmarksStore(database: try Database(path: ":memory:"))
        #expect(throws: (any Error).self) { try store.add(place: .local, path: "Sites") }
    }
}
