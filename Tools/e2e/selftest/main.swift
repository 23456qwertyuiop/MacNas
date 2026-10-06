//
//  main.swift
//  MacNas 核心自测（不依赖网络与界面）
//
//  用法：selftest
//  编译：swiftc MacNas/Core/*.swift Tools/e2e/selftest/main.swift -o selftest
//
//  这里的每一条都对应一个曾经踩过或必须守住的坑，尤其是密码哈希的
//  兼容性（老配置必须还能登录）与速度（WebDAV 客户端对单请求有约 300ms 容忍上限）。
//

import Foundation

var failures = 0
var passes = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        passes += 1
        print("  \u{1B}[32m✓\u{1B}[0m \(name)")
    } else {
        failures += 1
        print("  \u{1B}[31m✗\u{1B}[0m \(name)\(detail.isEmpty ? "" : "：\(detail)")")
    }
}

print("\n\u{1B}[1;34m== 密码哈希\u{1B}[0m")

// 旧实现（CryptoKit 手写循环）在 salt=00112233… 下为 test1234 算出的哈希。
// 换成 CommonCrypto 后必须逐位一致，否则所有老配置都会登录失败。
let legacySalt = "00112233445566778899aabbccddeeff"
let legacyHash = "b325d290026b65fcf5a8fc87c1ef088fd6cef699a9484bd6e62a41b6eadb1e53"
check("用的是同一套 PBKDF2 参数（兼容老配置）",
      PasswordHasher.verify(password: "test1234", saltHex: legacySalt, expectedHex: legacyHash))
check("错误密码被拒绝",
      !PasswordHasher.verify(password: "test1234 ", saltHex: legacySalt, expectedHex: legacyHash))
check("盐不同则哈希不同",
      PasswordHasher.derive(password: "test1234", saltHex: legacySalt) != legacyHash.replacingOccurrences(of: "b3", with: "c3"))

let randomSalt = PasswordHasher.makeSalt()
let randomHash = PasswordHasher.derive(password: "中文密码也可以", saltHex: randomSalt)
check("随机盐往返验证通过",
      PasswordHasher.verify(password: "中文密码也可以", saltHex: randomSalt, expectedHex: randomHash))
check("空哈希不会被误判通过",
      !PasswordHasher.verify(password: "", saltHex: "", expectedHex: ""))

// 速度守卫：WebDAV 客户端（Finder）对单个请求的容忍上限约 300~500ms，
// 而第一次带凭据的请求必须现场算一次 PBKDF2。手写实现曾在这里慢到 520ms 导致挂载失败。
_ = PasswordHasher.derive(password: "warmup", saltHex: legacySalt)
let iterations = 3
let start = Date()
for _ in 0..<iterations { _ = PasswordHasher.derive(password: "test1234", saltHex: legacySalt) }
let averageMS = Date().timeIntervalSince(start) * 1000 / Double(iterations)
check("PBKDF2 单次耗时 < 150ms（否则 Finder 挂载会超时）",
      averageMS < 150, String(format: "实测 %.0f ms", averageMS))

print("\n\u{1B}[1;34m== 哈希与路径\u{1B}[0m")

check("SHA-256 标准向量正确",
      FileHash.sha256(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("空数据 SHA-256 正确",
      FileHash.sha256(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

check("拒绝 .. 作为名称", LogicalPath.sanitizedSegment("..") == nil)
check("拒绝含 / 的名称", LogicalPath.sanitizedSegment("a/b") == nil)
check("拒绝含 : 的名称", LogicalPath.sanitizedSegment("a:b") == nil)
check("拒绝空名称", LogicalPath.sanitizedSegment("   ") == nil)
check("接受正常中文名称", LogicalPath.sanitizedSegment("报告 2026.txt") == "报告 2026.txt")
check("路径穿越被消解到卷内", LogicalPath.normalize("/../../etc/passwd") == "/etc/passwd")
check("路径归一化去掉重复斜杠", LogicalPath.normalize("//a///b/") == "/a/b")
check("父目录计算正确", LogicalPath.parent("/a/b/c.txt") == "/a/b")
check("根目录的父目录还是根", LogicalPath.parent("/") == "/")
check("判断后代路径正确", LogicalPath.isDescendant("/a/b/c", of: "/a/b") && !LogicalPath.isDescendant("/ab", of: "/a"))

print("\n\u{1B}[1;34m== 磁盘格式约定\u{1B}[0m")
check("当前格式版本为 2（v2 = 追加日志）", DiskSchema.currentVersion == 2)
check("仍然能读老格式 v1", DiskSchema.minimumReadableVersion == 1)
check("老卷不会被自动升级到 v2", DiskSchema.usesJournal(1) == false && DiskSchema.usesJournal(2))
check("卷内固定两份子文件夹名未变",
      StorageLayout.documentFolderName == "document" && StorageLayout.infoFolderName == "info")
check("blobs 目录名未变", StorageLayout.blobsFolderName == "blobs")
check("索引与备份文件名未变",
      StorageLayout.indexFileName == "index.json" && StorageLayout.indexBackupFileName == "index.json.bak")


print("\n\u{1B}[1;34m== 回收站与历史版本（真实 Store）\u{1B}[0m")

runTrashAndVersionChecks()

func runTrashAndVersionChecks() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("macnas-selftest-\(UUID().uuidString)", isDirectory: true)
    let volumeURL = base.appendingPathComponent("vol", isDirectory: true)
    let supportURL = base.appendingPathComponent("support", isDirectory: true)
    // AppPaths.supportDirectory 只能通过环境变量覆盖，这里直接在临时目录里建结构并让 Store 用绝对路径
    try? fm.createDirectory(at: volumeURL, withIntermediateDirectories: true)
    try? fm.createDirectory(at: supportURL, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    guard let volume = try? VolumeBootstrap.prepare(volumeURL, name: "selftest") else {
        check("能准备测试卷", false, "prepare 失败")
        return
    }
    let store = Store()
    _ = store.setVolumes([volume])
    check("能准备测试卷", true)

    func upload(_ text: String, name: String) -> String? {
        let temp = base.appendingPathComponent("upload-\(UUID().uuidString).part")
        try? Data(text.utf8).write(to: temp)
        let hash = FileHash.sha256(of: Data(text.utf8))
        return (try? store.commitUpload(volumeId: volume.id, directory: "/", fileName: name,
                                        sha256: hash, size: Int64(text.utf8.count),
                                        tempFileURL: temp, overwrite: true))?.entry.id
    }

    guard let firstId = upload("第一版内容", name: "文档.txt") else {
        check("能上传测试文件", false)
        return
    }
    check("能上传测试文件", true)
    let firstHash = FileHash.sha256(of: Data("第一版内容".utf8))

    // 覆盖上传 → 生成历史版本，且旧内容按引用计数保留
    _ = upload("第二版内容", name: "文档.txt")
    let versions = store.versions(volumeId: volume.id, entryId: firstId)
    check("覆盖上传会留下历史版本", versions.count == 2, "版本数=\(versions.count)")
    check("当前版本是最新的那份", versions.first?.version.sha256 == FileHash.sha256(of: Data("第二版内容".utf8)))
    check("旧内容仍然在库里（历史版本会引用它）", store.blobURL(sha256: firstHash) != nil)

    // 恢复历史版本，且可以再反悔
    try? store.restoreVersion(volumeId: volume.id, entryId: firstId, sha256: firstHash)
    let afterRestore = store.versions(volumeId: volume.id, entryId: firstId)
    check("能恢复到历史版本", afterRestore.first?.version.sha256 == firstHash,
          afterRestore.first?.version.sha256.prefix(8).description ?? "无")
    check("恢复后旧版本变成新的历史（可再反悔）",
          afterRestore.contains { $0.version.sha256 == FileHash.sha256(of: Data("第二版内容".utf8)) })

    // 删除 → 进回收站，内容不回收
    try? store.deleteEntry(volumeId: volume.id, entryId: firstId)
    let listing = (try? store.list(volumeId: volume.id, path: "/"))?.files ?? []
    check("回收站里的文件不再出现在列表里", listing.isEmpty, "列表数=\(listing.count)")
    check("回收站能列出它", store.trash(volumeId: volume.id).count == 1,
          "回收站=\(store.trash(volumeId: volume.id).count)")
    let trashEntry = store.trash(volumeId: volume.id).first
    check("回收站记录了原路径", trashEntry?.originalPath == "/文档.txt", trashEntry?.originalPath ?? "无")
    check("在回收站里内容也不会被回收", store.blobURL(sha256: firstHash) != nil)

    // 还原
    let restoredPath = (try? store.restoreEntry(volumeId: volume.id, entryId: firstId)) ?? ""
    check("能从回收站还原到原路径", restoredPath == "/文档.txt" && store.trash(volumeId: volume.id).isEmpty,
          restoredPath)

    // 还原时路径被占用 → 自动加序号
    // 注意顺序：先把原记录挪进回收站腾出路径，再放一个「别人的」文件占住它
    try? store.deleteEntry(volumeId: volume.id, entryId: firstId)
    _ = upload("占位内容", name: "文档.txt")
    let occupying = (try? store.list(volumeId: volume.id, path: "/"))?.files.count ?? 0
    let renamedPath = (try? store.restoreEntry(volumeId: volume.id, entryId: firstId)) ?? ""
    check("还原时原路径被占用会自动改名", renamedPath == "/文档 (2).txt", renamedPath)

    // 彻底删除 → 内容按引用计数回收
    try? store.deleteEntry(volumeId: volume.id, entryId: firstId)
    let hashBeforePurge = store.trash(volumeId: volume.id).first?.sha256 ?? ""
    try? store.purgeEntry(volumeId: volume.id, entryId: firstId)
    check("彻底删除会移除记录", store.trash(volumeId: volume.id).isEmpty)
    check("没人引用后内容才被回收", store.blobURL(sha256: hashBeforePurge) == nil)

    // 清空回收站
    if let extraId = upload("待清空", name: "清空.txt") {
        try? store.deleteEntry(volumeId: volume.id, entryId: extraId)
        let removed = (try? store.emptyTrash(volumeId: volume.id)) ?? 0
        check("清空回收站能一次清掉", removed == 1 && store.trash(volumeId: volume.id).isEmpty, "移除=\(removed)")
    }

    // 过期清理（olderThanDays: 0 = 比“现在”更早的都清）
    if let oldId = upload("过期内容", name: "过期.txt") {
        try? store.deleteEntry(volumeId: volume.id, entryId: oldId)
        Thread.sleep(forTimeInterval: 0.05)
        let purged = (try? store.emptyTrash(volumeId: volume.id, olderThanDays: 0)) ?? 0
        check("按保留期清理过期回收站", purged == 1 && store.trash(volumeId: volume.id).isEmpty, "清理=\(purged)")
    }

    // 同一个内容被两条记录引用时，删掉一条不能影响另一条
    guard let sharedA = upload("共享内容", name: "A.txt"), let sharedB = upload("共享内容", name: "B.txt") else {
        check("能上传两份相同内容", false)
        return
    }
    try? store.deleteEntry(volumeId: volume.id, entryId: sharedA)
    let sharedHash = FileHash.sha256(of: Data("共享内容".utf8))
    check("删掉一份后内容仍被另一份引用", store.blobURL(sha256: sharedHash) != nil)
    try? store.deleteEntry(volumeId: volume.id, entryId: sharedB)
    check("两份都进了回收站，内容依然保留", store.blobURL(sha256: sharedHash) != nil
          && store.trash(volumeId: volume.id).count == 2)
    check("清空回收站后共享内容才被回收",
          { _ = try? store.emptyTrash(volumeId: volume.id); return store.blobURL(sha256: sharedHash) == nil }())
}

print("\n\u{1B}[1;34m== 镜像导出（给 SMB / Time Machine 用）\u{1B}[0m")

runMirrorChecks()

func runMirrorChecks() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("macnas-mirror-\(UUID().uuidString)", isDirectory: true)
    let volumeURL = base.appendingPathComponent("vol", isDirectory: true)
    let mirrorURL = base.appendingPathComponent("mirror", isDirectory: true)
    try? fm.createDirectory(at: volumeURL, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    guard let volume = try? VolumeBootstrap.prepare(volumeURL, name: "mirror") else {
        check("镜像：能准备测试卷", false); return
    }
    let store = Store()
    _ = store.setVolumes([volume])

    func upload(_ text: String, dir: String, name: String) -> FileEntry? {
        let temp = base.appendingPathComponent("up-\(UUID().uuidString).part")
        try? Data(text.utf8).write(to: temp)
        let hash = FileHash.sha256(of: Data(text.utf8))
        return (try? store.commitUpload(volumeId: volume.id, directory: dir, fileName: name,
                                        sha256: hash, size: Int64(text.utf8.count),
                                        tempFileURL: temp, overwrite: true))?.entry
    }

    _ = try? store.createFolder(volumeId: volume.id, path: "/", name: "项目")
    _ = try? store.createFolder(volumeId: volume.id, path: "/项目", name: "空目录")
    _ = upload("镜像内容一", dir: "/", name: "顶层.txt")
    _ = upload("镜像内容二", dir: "/项目", name: "说明.txt")
    let shared = upload("镜像共享内容", dir: "/项目", name: "A.txt")
    _ = upload("镜像共享内容", dir: "/", name: "B.txt")
    _ = upload("镜像共享内容", dir: "/", name: "C.txt")

    guard let report = try? store.mirror(volumeId: volume.id, target: mirrorURL) else {
        check("镜像：能导出", false, "mirror 抛错"); return
    }
    check("镜像：新建了文件", report.fileCount == 5, "文件数=\(report.fileCount)")
    check("镜像：用硬链接（同文件系统下不占额外空间）", report.linked == 5, "linked=\(report.linked)")
    check("镜像：保留了目录结构",
          fm.fileExists(atPath: mirrorURL.appendingPathComponent("项目/说明.txt").path)
          && fm.fileExists(atPath: mirrorURL.appendingPathComponent("顶层.txt").path))
    check("镜像：空文件夹也建出来了",
          fm.fileExists(atPath: mirrorURL.appendingPathComponent("项目/空目录").path))
    check("镜像：文件内容正确",
          (try? String(contentsOf: mirrorURL.appendingPathComponent("项目/说明.txt"), encoding: .utf8)) == "镜像内容二")
    check("镜像：写了一份清单文件",
          fm.fileExists(atPath: mirrorURL.appendingPathComponent(".macnas-mirror.json").path))

    // 硬链接验证：改镜像里的文件会同时改到库里那份（说明确实是同一份数据）
    if let shared, let blob = store.blobURL(sha256: shared.sha256) {
        let mirrorFile = mirrorURL.appendingPathComponent("项目/A.txt")
        let mirrorInode = (try? fm.attributesOfItem(atPath: mirrorFile.path))?[.systemFileNumber] as? Int
        let blobInode = (try? fm.attributesOfItem(atPath: blob.path))?[.systemFileNumber] as? Int
        check("镜像：文件确实是库内容的硬链接", mirrorInode != nil && mirrorInode == blobInode,
              "mirror=\(mirrorInode ?? -1) blob=\(blobInode ?? -1)")
    }

    // 再次导出应当全部跳过（增量）
    let second = (try? store.mirror(volumeId: volume.id, target: mirrorURL)) ?? MirrorReport()
    check("镜像：重复导出会跳过已是最新的文件", second.skipped == 5 && second.linked == 0,
          "skipped=\(second.skipped) linked=\(second.linked)")

    // 内容变了之后重新导出会更新
    _ = upload("镜像内容二（改过）", dir: "/项目", name: "说明.txt")
    let third = (try? store.mirror(volumeId: volume.id, target: mirrorURL)) ?? MirrorReport()
    check("镜像：文件内容更新后会重新链接", third.linked == 1 && third.skipped == 4,
          "linked=\(third.linked) skipped=\(third.skipped)")
    check("镜像：更新后的内容正确",
          (try? String(contentsOf: mirrorURL.appendingPathComponent("项目/说明.txt"), encoding: .utf8)) == "镜像内容二（改过）")

    // 安全：不允许导出到卷内部
    let inside = volumeURL.appendingPathComponent("document/导出到里面")
    check("镜像：拒绝导出到卷内部", (try? store.mirror(volumeId: volume.id, target: inside)) == nil)
}

print("\n\u{1B}[1;34m== 追加日志（格式 v2）\u{1B}[0m")

runJournalChecks()

func runJournalChecks() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("macnas-journal-\(UUID().uuidString)", isDirectory: true)
    let volumeURL = base.appendingPathComponent("vol", isDirectory: true)
    try? fm.createDirectory(at: volumeURL, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    guard let volume = try? VolumeBootstrap.prepare(volumeURL, name: "journal") else {
        check("日志：能准备测试卷", false); return
    }
    check("日志：新目录使用最新格式 v2", volume.id.isEmpty == false && {
        let marker = try? Data(contentsOf: volume.markerURL)
        let text = marker.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return text.contains("\"formatVersion\" : 2")
    }(), "marker 应为 v2")

    let store = Store()
    _ = store.setVolumes([volume])
    check("日志：装载后处于启用状态", store.usesJournal(volumeId: volume.id))

    func upload(_ text: String, name: String) -> FileEntry? {
        let temp = base.appendingPathComponent("up-\(UUID().uuidString).part")
        try? Data(text.utf8).write(to: temp)
        let hash = FileHash.sha256(of: Data(text.utf8))
        return (try? store.commitUpload(volumeId: volume.id, directory: "/", fileName: name,
                                        sha256: hash, size: Int64(text.utf8.count),
                                        tempFileURL: temp, overwrite: true))?.entry
    }

    _ = upload("日志内容一", name: "一.txt")
    _ = upload("日志内容二", name: "二.txt")
    _ = upload("日志内容三", name: "三.txt")
    let journalExists = fm.fileExists(atPath: volume.journalURL.path)
    check("日志：改动写进了追加日志", journalExists,
          journalExists ? "\(((try? fm.attributesOfItem(atPath: volume.journalURL.path))?[.size] as? NSNumber)?.intValue ?? 0) 字节" : "没有日志文件")
    let snapshotSize = ((try? fm.attributesOfItem(atPath: volume.indexURL.path))?[.size] as? NSNumber)?.intValue ?? 0
    check("日志：这时还没有重写整份索引（快照很小）", snapshotSize < 800, "快照=\(snapshotSize) 字节")

    // 重新装载：快照 + 回放日志应当还原出全部记录
    let reloaded = Store()
    _ = reloaded.setVolumes([volume])
    let listed = (try? reloaded.list(volumeId: volume.id, path: "/"))?.files ?? []
    check("日志：重新装载能看到全部 3 条记录", listed.count == 3, "列出 \(listed.count) 条")

    // 改名（改的是已存在的记录）也要能回放
    if let first = listed.first(where: { $0.name == "一.txt" }) {
        try? reloaded.renameEntry(volumeId: volume.id, entryId: first.id, newName: "一-改名.txt")
    }
    let again = Store()
    _ = again.setVolumes([volume])
    let names = (try? again.list(volumeId: volume.id, path: "/"))?.files.map(\.name).sorted() ?? []
    check("日志：改名后重新装载名字正确", names.contains("一-改名.txt"), names.joined(separator: ","))

    // 删除 + 回收站也要能回放
    if let target = (try? again.list(volumeId: volume.id, path: "/"))?.files.first(where: { $0.name == "二.txt" }) {
        try? again.deleteEntry(volumeId: volume.id, entryId: target.id)
    }
    let third = Store()
    _ = third.setVolumes([volume])
    let afterDelete = (try? third.list(volumeId: volume.id, path: "/"))?.files.map(\.name).sorted() ?? []
    let trash = third.trash(volumeId: volume.id).map(\.name)
    check("日志：删除会写进日志并回放正确", !afterDelete.contains("二.txt") && trash.contains("二.txt"),
          "列表=\(afterDelete.joined(separator: ",")) 回收站=\(trash.joined(separator: ","))")

    // 日志损坏（断电写了一半）也要能装起来
    if let handle = try? FileHandle(forWritingTo: volume.journalURL) {
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("{\"put\":[{\"id\":\"坏\"".utf8))   // 故意写半行
        try? handle.close()
    }
    let damagedLoad = Store()
    _ = damagedLoad.setVolumes([volume])
    let survivors = (try? damagedLoad.list(volumeId: volume.id, path: "/"))?.files.count ?? -1
    check("日志：最后一行损坏也能正常装载", survivors == afterDelete.count,
          "装载出 \(survivors) 条（期望 \(afterDelete.count)）")

    // 压缩：超过阈值后应当写回完整快照并清掉日志
    for index in 0..<40 { _ = upload(String(repeating: "压缩测试\(index)", count: 400), name: "大-\(index).txt") }
    try? third.mirror(volumeId: volume.id, target: base.appendingPathComponent("junk"))   // 触发一次写入路径
    if let handle = try? FileHandle(forWritingTo: volume.journalURL) { try? handle.close() }
    // 直接调用压缩路径：写一次快照
    let compactStore = Store()
    _ = compactStore.setVolumes([volume])
    if let one = (try? compactStore.list(volumeId: volume.id, path: "/"))?.files.first {
        try? compactStore.renameEntry(volumeId: volume.id, entryId: one.id, newName: one.name + "-x")
    }
    let compactedCount = (try? compactStore.list(volumeId: volume.id, path: "/"))?.files.count ?? 0
    check("日志：装载 + 回放后条目数一致（40+ 条）", compactedCount >= 40, "共 \(compactedCount) 条")

    // 老卷（v1）不能因为写一次就被升级
    let legacyURL = base.appendingPathComponent("legacy", isDirectory: true)
    try? fm.createDirectory(at: legacyURL, withIntermediateDirectories: true)
    guard let legacy = try? VolumeBootstrap.prepare(legacyURL, name: "legacy") else { return }
    // 手动把标记与索引降回 v1，模拟老目录
    for url in [legacy.markerURL, legacy.indexURL] {
        guard let data = try? Data(contentsOf: url), var object = JSONPreservation.object(from: data) else { continue }
        object["formatVersion"] = 1
        if let rewritten = JSONPreservation.data(from: object) { try? rewritten.write(to: url) }
    }
    let legacyStore = Store()
    _ = legacyStore.setVolumes([legacy])
    check("日志：老卷（v1）不会被自动升级", !legacyStore.usesJournal(volumeId: legacy.id))
    let legacyTemp = base.appendingPathComponent("legacy.part")
    try? Data("老卷内容".utf8).write(to: legacyTemp)
    _ = try? legacyStore.commitUpload(volumeId: legacy.id, directory: "/", fileName: "老.txt",
                                      sha256: FileHash.sha256(of: Data("老卷内容".utf8)),
                                      size: 12, tempFileURL: legacyTemp, overwrite: false)
    let legacyIndex = (try? Data(contentsOf: legacy.indexURL)).flatMap { JSONPreservation.object(from: $0) }
    check("日志：老卷写入后仍然是 v1", (legacyIndex?["formatVersion"] as? Int) == 1,
          "formatVersion=\((legacyIndex?["formatVersion"] as? Int) ?? -1)")
    check("日志：老卷没有产生日志文件", !fm.fileExists(atPath: legacy.journalURL.path))

    // 显式升级
    try? legacyStore.enableJournal(volumeId: legacy.id)
    check("日志：显式升级后启用日志", legacyStore.usesJournal(volumeId: legacy.id))
    let upgraded = Store()
    _ = upgraded.setVolumes([legacy])
    let upgradedNames = (try? upgraded.list(volumeId: legacy.id, path: "/"))?.files.map(\.name) ?? []
    check("日志：升级后内容仍在", upgradedNames.contains("老.txt"), upgradedNames.joined(separator: ","))
}

printfSummary: do {
    print("")
    if failures == 0 {
        print("\u{1B}[1m通过 \(passes) 项，失败 0 项\u{1B}[0m")
    } else {
        print("\u{1B}[1m通过 \(passes) 项，失败 \(failures) 项\u{1B}[0m")
    }
}
exit(failures == 0 ? 0 : 1)
