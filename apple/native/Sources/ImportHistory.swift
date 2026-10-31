import Foundation
import SwiftUI

struct ImportIssue:Codable,Identifiable,Equatable {
    var id=UUID()
    let file:String
    let reason:String
    var coverOnly=false
    init(file:String,error:Error,coverOnly:Bool=false) {
        self.file=String(decoding:(file as NSString).lastPathComponent.utf8.prefix(255),as:UTF8.self);self.coverOnly=coverOnly
        let cause=(error as? ZIPGameImport.ArchiveError)?.underlying ?? error
        if cause is VetaError || cause is CloudImportPreparation.Failure || cause is DirectCloudError || cause is KrafifySharedError {
            reason=String(decoding:cause.localizedDescription.utf8.prefix(400),as:UTF8.self)
        } else {
            // System/provider errors can contain private URLs, tokens and paths.
            // Keep only a useful error domain/code; never persist their userInfo.
            let value=cause as NSError
            reason=L10n.text("No se pudo leer o importar este archivo.")+" (\(value.domain): \(value.code))"
        }
    }
}
struct ImportReport:Codable,Identifiable {
    var id=UUID()
    var date=Date()
    let processed:Int
    let covers:Int
    let issues:[ImportIssue]
}
enum ImportHistory {
    static func url(_ root:URL)->URL {root.appendingPathComponent("import-history.json")}
    static func read(_ root:URL)throws->[ImportReport] {
        let path=url(root)
        guard FileManager.default.fileExists(atPath:path.path) else{return []}
        guard (try path.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=32*1024*1024 else {throw VetaError.message("No se pudo leer el historial de importación.")}
        return try JSONDecoder().decode([ImportReport].self,from:Data(contentsOf:path))
    }
    static func append(_ report:ImportReport,root:URL)throws {
        var reports=try read(root);reports.insert(report,at:0)
        if reports.count>20 {reports=Array(reports.prefix(20))}
        while reports.count>1 && reports.reduce(0,{$0+$1.issues.count})>20_000 {reports.removeLast()}
        var data=try JSONEncoder().encode(reports)
        while reports.count>1 && data.count>30*1024*1024 {
            reports.removeLast();data=try JSONEncoder().encode(reports)
        }
        guard data.count<=32*1024*1024 else {throw VetaError.message("No se pudo guardar el historial de importación. Los juegos procesados se conservaron.")}
        try data.write(to:url(root),options:.atomic)
    }
}
struct ImportHistoryView:View {
    let root:URL
    @State private var reports:[ImportReport]=[]
    @State private var failure:String?
    var body:some View {
        List {
            if let failure {Text(failure).foregroundStyle(.red)}
            if reports.isEmpty && failure == nil {Text("Todavía no hay importaciones registradas.")}
            ForEach(reports) {report in
                NavigationLink {
                    List {
                        Section {
                            Text(report.date,style:.date);Text(report.date,style:.time)
                            Text(L10n.format("Juegos procesados: %d. Portadas añadidas: %d.",report.processed,report.covers))
                        }
                        Section("Archivos con incidencias") {
                            if report.issues.isEmpty {Text("Sin errores.")}
                            ForEach(report.issues) {issue in
                                VStack(alignment:.leading,spacing:6) {
                                    Text(issue.file).font(.headline).textSelection(.enabled)
                                    if issue.coverOnly {Text("El juego se conservó; falló su portada.").foregroundStyle(.secondary)}
                                    Text(L10n.text(issue.reason)).font(.subheadline).textSelection(.enabled)
                                }.padding(.vertical,4)
                            }
                        }
                    }.navigationTitle("Detalle de importación").navigationBarTitleDisplayMode(.inline)
                } label:{
                    VStack(alignment:.leading,spacing:5) {
                        Text(report.date,format:.dateTime.day().month().hour().minute()).font(.headline)
                        Text(L10n.format("Juegos procesados: %d. Archivos con incidencias: %d.",report.processed,report.issues.count)).font(.subheadline)
                    }.padding(.vertical,5)
                }.accessibilityIdentifier("import-report-\(report.id)")
            }
            Section {Text("El historial reciente se guarda en VETA y no se envía automáticamente. Los archivos originales no se modifican.").font(.footnote).foregroundStyle(.secondary)}
        }.navigationTitle("Historial de importación").navigationBarTitleDisplayMode(.inline)
            .task {do{reports=try ImportHistory.read(root)}catch{failure=L10n.text("No se pudo leer el historial de importación.")}}
    }
}
