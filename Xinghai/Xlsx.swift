import Compression
import Foundation

/* =========================================================
   xlsx 读写引擎（Swift 手写 OOXML + ZIP，无第三方库）
   —— 与安卓端 Xlsx.java / WorkExport.java 的输出口径对齐：
      每个月一张工作表，工作表名形如 2026.10，首行标题、次行表头。
   ========================================================= */

private let crcTable: [UInt32] = {
    var t = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        t[i] = c
    }
    return t
}()

private func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

private extension Data {
    mutating func u16(_ v: Int) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
    }
    mutating func u32(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 24) & 0xFF))
    }
    func u16(at i: Int) -> Int { Int(self[i]) | (Int(self[i + 1]) << 8) }
    func u32(at i: Int) -> UInt32 {
        UInt32(self[i]) | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }
}

enum XlsxError: Error {
    case notZip
    case broken(String)
    var msg: String {
        switch self {
        case .notZip: return "不是有效的 xlsx 文件"
        case .broken(let s): return s
        }
    }
}

enum Xlsx {

    /* ================= 数据结构 ================= */

    struct Sheet {
        var name = ""
        var title = ""
        var header: [String] = []
        var rows: [[String]] = []
    }

    /// 读出来的工作簿：names 与 sheets 一一对应，sheet 是「行 → 列」的文本网格
    struct Book {
        var names: [String] = []
        var sheets: [[[String]]] = []
    }

    /* ================= 写 ================= */

    static func write(_ sheets: [Sheet]) -> Data {
        var files: [(String, Data)] = []
        files.append(("[Content_Types].xml", Data(typesXml(sheets).utf8)))
        files.append(("_rels/.rels", Data(relsXml.utf8)))
        files.append(("xl/workbook.xml", Data(workbookXml(sheets).utf8)))
        files.append(("xl/_rels/workbook.xml.rels", Data(workbookRels(sheets).utf8)))
        files.append(("xl/styles.xml", Data(stylesXml.utf8)))
        for (i, s) in sheets.enumerated() {
            files.append(("xl/worksheets/sheet\(i + 1).xml", Data(sheetXml(s).utf8)))
        }
        return zip(files)
    }

    private static func esc(_ s: String) -> String {
        var o = ""
        for ch in s {
            switch ch {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&apos;"
            default: o.append(ch)
            }
        }
        return o
    }

    private static let header =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    private static func typesXml(_ sheets: [Sheet]) -> String {
        var s = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        s += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        s += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        s += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        s += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        for i in sheets.indices {
            s += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        return s + "</Types>"
    }

    private static let relsXml = header
        + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        + "</Relationships>"

    private static func workbookXml(_ sheets: [Sheet]) -> String {
        var s = header
        s += "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        s += "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>"
        for (i, sh) in sheets.enumerated() {
            let nm = sh.name.isEmpty ? "Sheet\(i + 1)" : sh.name
            // 工作表名不能含 [ ] : * ? / \，统一替换掉
            var safe = ""
            for ch in nm { safe.append("[]:*?/\\".contains(ch) ? " " : ch) }
            s += "<sheet name=\"\(esc(safe))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        return s + "</sheets></workbook>"
    }

    private static func workbookRels(_ sheets: [Sheet]) -> String {
        var s = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in sheets.indices {
            s += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        s += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        return s + "</Relationships>"
    }

    /// 0=常规 1=标题(粗体14) 2=表头(粗体+浅灰底) 3=日期(yyyy/m/d)
    private static let stylesXml = header + """
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy/m/d"/></numFmts>\
    <fonts count="3">\
    <font><sz val="11"/><color rgb="FF000000"/><name val="宋体"/></font>\
    <font><b/><sz val="14"/><color rgb="FF000000"/><name val="宋体"/></font>\
    <font><b/><sz val="11"/><color rgb="FF000000"/><name val="宋体"/></font>\
    </fonts>\
    <fills count="3">\
    <fill><patternFill patternType="none"/></fill>\
    <fill><patternFill patternType="gray125"/></fill>\
    <fill><patternFill patternType="solid"><fgColor rgb="FFF2F4F8"/><bgColor indexed="64"/></patternFill></fill>\
    </fills>\
    <borders count="2">\
    <border><left/><right/><top/><bottom/><diagonal/></border>\
    <border><left style="thin"><color rgb="FFD9DEE8"/></left><right style="thin"><color rgb="FFD9DEE8"/></right><top style="thin"><color rgb="FFD9DEE8"/></top><bottom style="thin"><color rgb="FFD9DEE8"/></bottom><diagonal/></border>\
    </borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="4">\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
    <xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>\
    <xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>\
    </cellXfs>\
    <cellStyles count="1"><cellStyle name="常规" xfId="0" builtinId="0"/></cellStyles>\
    </styleSheet>
    """

    /// 列号 → 字母（1→A, 27→AA）
    static func colName(_ n: Int) -> String {
        var v = n, s = ""
        while v > 0 {
            let r = (v - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            v = (v - 1) / 26
        }
        return s
    }

    private static func cell(_ col: Int, _ row: Int, _ text: String, style: Int) -> String {
        let ref = colName(col) + String(row)
        if text.isEmpty && style == 0 { return "" }
        if text.isEmpty { return "<c r=\"\(ref)\" s=\"\(style)\"/>" }
        return "<c r=\"\(ref)\" s=\"\(style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(esc(text))</t></is></c>"
    }

    private static func sheetXml(_ sh: Sheet) -> String {
        let cols = max(sh.header.count, sh.rows.map { $0.count }.max() ?? 0)
        var s = header
        s += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if cols > 0 {
            s += "<cols>"
            for c in 1...cols {
                let w = c == 1 ? 12 : (c == 2 ? 18 : (c == 3 ? 22 : 14))
                s += "<col min=\"\(c)\" max=\"\(c)\" width=\"\(w)\" customWidth=\"1\"/>"
            }
            s += "</cols>"
        }
        s += "<sheetData>"
        var rowNo = 1
        if !sh.title.isEmpty, cols > 0 {
            s += "<row r=\"1\" ht=\"24\" customHeight=\"1\">" + cell(1, 1, sh.title, style: 1) + "</row>"
            rowNo = 2
        }
        if !sh.header.isEmpty {
            s += "<row r=\"\(rowNo)\" ht=\"20\" customHeight=\"1\">"
            for (i, h) in sh.header.enumerated() { s += cell(i + 1, rowNo, h, style: 2) }
            s += "</row>"
            rowNo += 1
        }
        for r in sh.rows {
            s += "<row r=\"\(rowNo)\">"
            for (i, v) in r.enumerated() where !v.isEmpty {
                s += cell(i + 1, rowNo, v, style: 3)
            }
            s += "</row>"
            rowNo += 1
        }
        s += "</sheetData>"
        if !sh.title.isEmpty, cols > 1 {
            s += "<mergeCells count=\"1\"><mergeCell ref=\"A1:\(colName(cols))1\"/></mergeCells>"
        }
        return s + "</worksheet>"
    }

    /* ================= ZIP 打包（stored，不压缩） ================= */

    static func zip(_ files: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (name, payload) in files {
            let nameData = Data(name.utf8)
            let crc = crc32(payload)
            let offset = UInt32(out.count)
            out.u32(0x04034b50)
            out.u16(20)          // version needed
            out.u16(0x0800)      // UTF-8 文件名
            out.u16(0)           // stored
            out.u16(0)           // time
            out.u16(0x21)        // date: 1980-01-01
            out.u32(crc)
            out.u32(UInt32(payload.count))
            out.u32(UInt32(payload.count))
            out.u16(nameData.count)
            out.u16(0)
            out.append(nameData)
            out.append(payload)

            central.u32(0x02014b50)
            central.u16(20)
            central.u16(20)
            central.u16(0x0800)
            central.u16(0)
            central.u16(0)
            central.u16(0x21)
            central.u32(crc)
            central.u32(UInt32(payload.count))
            central.u32(UInt32(payload.count))
            central.u16(nameData.count)
            central.u16(0)   // extra
            central.u16(0)   // comment
            central.u16(0)   // disk
            central.u16(0)   // internal
            central.u32(0)   // external
            central.u32(offset)
            central.append(nameData)
        }
        let cdOffset = UInt32(out.count)
        let cdSize = UInt32(central.count)
        out.append(central)
        out.u32(0x06054b50)
        out.u16(0); out.u16(0)
        out.u16(files.count); out.u16(files.count)
        out.u32(cdSize); out.u32(cdOffset)
        out.u16(0)
        return out
    }

    /* ================= ZIP 解包 ================= */

    private static func inflate(_ src: Data, hint: Int) -> Data? {
        let cap = max(hint > 0 ? hint : 1, 1 << 16)
        let trySizes = [cap, cap * 8, cap * 64, 1 << 24]
        for size in trySizes {
            var dst = Data(count: size)
            let n = dst.withUnsafeMutableBytes { (dp: UnsafeMutableRawBufferPointer) -> Int in
                guard let d = dp.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return src.withUnsafeBytes { (sp: UnsafeRawBufferPointer) -> Int in
                    guard let s = sp.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, size, s, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 { return dst.prefix(n) }
        }
        return nil
    }

    static func unzip(_ data: Data) throws -> [String: Data] {
        guard data.count > 22 else { throw XlsxError.notZip }
        // 从尾部找 EOCD
        var eocd = -1
        let lower = max(0, data.count - 66000)
        var i = data.count - 22
        while i >= lower {
            if data.u32(at: i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw XlsxError.notZip }
        let count = data.u16(at: eocd + 10)
        var p = Int(data.u32(at: eocd + 16))
        var out: [String: Data] = [:]
        for _ in 0..<count {
            guard p + 46 <= data.count, data.u32(at: p) == 0x02014b50 else { break }
            let method = data.u16(at: p + 10)
            let compSize = Int(data.u32(at: p + 20))
            let rawSize = Int(data.u32(at: p + 24))
            let nameLen = data.u16(at: p + 28)
            let extraLen = data.u16(at: p + 30)
            let cmtLen = data.u16(at: p + 32)
            let localOff = Int(data.u32(at: p + 42))
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            p += 46 + nameLen + extraLen + cmtLen
            guard localOff + 30 <= data.count else { continue }
            let lNameLen = data.u16(at: localOff + 26)
            let lExtraLen = data.u16(at: localOff + 28)
            let start = localOff + 30 + lNameLen + lExtraLen
            guard start + compSize <= data.count else { continue }
            let blob = data.subdata(in: start..<(start + compSize))
            if method == 0 {
                out[name] = blob
            } else if method == 8 {
                if let d = inflate(blob, hint: rawSize) { out[name] = d }
            }
        }
        guard !out.isEmpty else { throw XlsxError.notZip }
        return out
    }

    /* ================= 读 xlsx ================= */

    static func read(_ data: Data) throws -> Book {
        let files = try unzip(data)
        var shared: [String] = []
        if let d = files["xl/sharedStrings.xml"] { shared = parseSharedStrings(d) }
        let dateStyles = parseStyles(files["xl/styles.xml"])

        // sheet 名与 rId 的对应关系：优先用 workbook.xml 顺序
        var names: [String] = []
        var targets: [String] = []
        if let wb = files["xl/workbook.xml"], let rels = files["xl/_rels/workbook.xml.rels"] {
            let pairs = parseWorkbook(wb)
            let relMap = parseRels(rels)
            for (name, rid) in pairs {
                names.append(name)
                var t = relMap[rid] ?? ""
                if t.hasPrefix("/") { t.removeFirst() }
                if !t.hasPrefix("xl/") { t = "xl/" + t }
                targets.append(t)
            }
        }
        // 兜底：直接扫 worksheets
        if targets.isEmpty {
            for k in files.keys where k.hasPrefix("xl/worksheets/") && k.hasSuffix(".xml") {
                targets.append(k)
            }
            targets.sort()
            names = targets.enumerated().map { "Sheet\($0.offset + 1)" }
        }

        var sheets: [[[String]]] = []
        for t in targets {
            guard let d = files[t] else { sheets.append([]); continue }
            sheets.append(parseSheet(d, shared: shared, dateStyles: dateStyles))
        }
        return Book(names: names, sheets: sheets)
    }

    private static func parseSharedStrings(_ d: Data) -> [String] {
        let p = XMLParser(data: d)
        let dele = SSTDelegate()
        p.delegate = dele
        p.parse()
        return dele.strings
    }

    /// 返回每个 cellXf 下标是否为日期格式
    private static func parseStyles(_ d: Data?) -> [Bool] {
        guard let d = d else { return [] }
        let p = XMLParser(data: d)
        let dele = StyleDelegate()
        p.delegate = dele
        p.parse()
        return dele.dateXf
    }

    private static func parseWorkbook(_ d: Data) -> [(String, String)] {
        let p = XMLParser(data: d)
        let dele = WorkbookDelegate()
        p.delegate = dele
        p.parse()
        return dele.pairs
    }

    private static func parseRels(_ d: Data) -> [String: String] {
        let p = XMLParser(data: d)
        let dele = RelsDelegate()
        p.delegate = dele
        p.parse()
        return dele.map
    }

    private static func parseSheet(_ d: Data, shared: [String], dateStyles: [Bool]) -> [[String]] {
        let p = XMLParser(data: d)
        let dele = SheetDelegate(shared: shared, dateStyles: dateStyles)
        p.delegate = dele
        p.parse()
        return dele.rows
    }
}

/* ================= XML 解析器 ================= */

private func colIndex(_ ref: String) -> Int {
    var n = 0
    for ch in ref.uppercased() {
        guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
        n = n * 26 + Int(a - 64)
    }
    return n
}

private final class SSTDelegate: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var cur: String?
    private var inT = false
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if e == "si" { cur = "" }
        if e == "t" && cur != nil { inT = true }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { if inT { cur? += s } }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        if e == "t" { inT = false }
        if e == "si" { strings.append(cur ?? ""); cur = nil }
    }
}

private final class StyleDelegate: NSObject, XMLParserDelegate {
    var dateXf: [Bool] = []
    private var customDates: Set<Int> = []
    private var xfFmt: [Int] = []
    private var inCellXfs = false
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String]) {
        if e == "cellXfs" { inCellXfs = true; return }
        if e == "numFmt", let id = a["numFmtId"].flatMap(Int.init),
           let code = a["formatCode"] {
            let c = code.lowercased()
            if c.contains("y") && (c.contains("m") || c.contains("d")) { customDates.insert(id) }
        }
        // cellStyleXfs 里的 xf 不能计入 cellXfs 下标
        if e == "xf", inCellXfs, let id = a["numFmtId"].flatMap(Int.init) { xfFmt.append(id) }
    }
    func parserDidEndDocument(_ p: XMLParser) {
        let builtin: Set<Int> = [14, 15, 16, 17, 18, 19, 20, 21, 22,
                                 27, 28, 29, 30, 31, 32, 33, 34, 35, 36,
                                 45, 46, 47, 50, 51, 52, 53, 54, 55, 56, 57, 58]
        // cellXfs 紧跟在 cellStyleXfs 之后，xfFmt 后半段是 cellXfs
        dateXf = xfFmt.map { builtin.contains($0) || customDates.contains($0) }
    }
}

private final class WorkbookDelegate: NSObject, XMLParserDelegate {
    var pairs: [(String, String)] = []
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String]) {
        if e == "sheet" {
            let name = a["name"] ?? ""
            let rid = a["r:id"] ?? a["id"] ?? ""
            pairs.append((name, rid))
        }
    }
}

private final class RelsDelegate: NSObject, XMLParserDelegate {
    var map: [String: String] = [:]
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String]) {
        if e == "Relationship", let id = a["Id"], let t = a["Target"] { map[id] = t }
    }
}

/// 逐行解析 worksheet，产出统一网格；数字按日期样式决定是否转 yyyy-MM-dd
private final class SheetDelegate: NSObject, XMLParserDelegate {
    let shared: [String]
    let dateStyles: [Bool]
    var rows: [[String]] = []
    private var cells: [Int: String] = [:]
    private var maxCol = 0
    private var curCol = 0
    private var curType = ""
    private var curStyle = -1
    private var buf = ""
    private var inV = false
    private var inT = false

    init(shared: [String], dateStyles: [Bool]) {
        self.shared = shared
        self.dateStyles = dateStyles
    }

    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String]) {
        switch e {
        case "row":
            cells = [:]; maxCol = 0
        case "c":
            curCol = colIndex(a["r"] ?? "")
            curType = a["t"] ?? ""
            curStyle = a["s"].flatMap(Int.init) ?? -1
            buf = ""
        case "v":
            if curType != "inlineStr" { inV = true; buf = "" }
        case "t":
            inT = true
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) {
        if inV || inT { buf += s }
    }

    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        switch e {
        case "v":
            inV = false
        case "t":
            inT = false
        case "c":
            var text = buf
            if curType == "s", let idx = Int(buf.trimmingCharacters(in: .whitespaces)),
               idx >= 0, idx < shared.count {
                text = shared[idx]
            } else if curType.isEmpty || curType == "n" {
                // 数字：若该单元格样式是日期，把 Excel 序列号还原成 yyyy-MM-dd
                let t = buf.trimmingCharacters(in: .whitespaces)
                let isDate = curStyle >= 0 && curStyle < dateStyles.count && dateStyles[curStyle]
                if isDate, let serial = Double(t), serial > 0 {
                    // Excel 1900 日期系统（含 1900 闰年 bug）→ 基准 1899-12-30
                    let days = Int(serial)
                    var comp = DateComponents()
                    comp.year = 1899; comp.month = 12; comp.day = 30
                    let cal = Calendar(identifier: .gregorian)
                    if let base = cal.date(from: comp),
                       let d = cal.date(byAdding: .day, value: days, to: base) {
                        let f = DateFormatter()
                        f.dateFormat = "yyyy-MM-dd"
                        f.locale = Locale(identifier: "en_US_POSIX")
                        text = f.string(from: d)
                    }
                }
            }
            if curCol > 0 {
                cells[curCol] = text
                maxCol = max(maxCol, curCol)
            }
            buf = ""
        case "row":
            var line = [String](repeating: "", count: maxCol)
            for (i, v) in cells where i <= maxCol { line[i - 1] = v }
            rows.append(line)
        default: break
        }
    }
}
