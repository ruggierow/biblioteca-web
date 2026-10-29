import Foundation
import SQLite3

/// Le a biblioteca do Kindle instalada neste Mac.
///
/// POR QUE SO O MAC TEM ISTO
///
/// A biblioteca do Kindle e um banco SQLite dentro do container do aplicativo
/// Kindle. No Windows o usuario nao tem o Kindle instalado, e no iPhone e no
/// Android nenhum aplicativo le os dados de outro. O Mac e o unico lugar onde
/// a informacao existe — e basta, porque a linha nova entra no biblioteca.txt
/// e e o ARQUIVO que viaja para os outros tres.
///
/// Duas coisas medidas em 29/10/2026, antes de escrever uma linha disto:
///
///   - o aplicativo NAO e sandboxed (nao ha com.apple.security.app-sandbox nos
///     entitlements), entao enxerga o container do Kindle;
///   - o container do Kindle NAO e protegido pelo TCC: um processo SEM Acesso
///     Total ao Disco le o banco. Ou seja, nenhum dialogo de permissao, nada
///     para o usuario configurar.
///
/// NAO USAR o XML do aplicativo classico (com.amazon.Kindle): esta velho e tem
/// um livro so.
enum Kindle {

    static let banco = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Containers/com.amazon.Lassen/Data/Library/Protected/BookData.sqlite")

    /// ZRAWBOOKTYPE classifica, e isso e melhor que adivinhar pelo titulo — ha
    /// dicionarios em marata e malaiala que nenhuma regra de nome pega.
    ///   10 = livro   11 = amostra   13 = documento pessoal   16 = dicionario
    ///
    /// Decisao do usuario (09/10/2026): a sincronizacao e so dos LIVROS.
    static let tipoLivro: Int32 = 10

    struct Livro {
        let asin: String
        let titulo: String
        let autor: String
        let ano: String
        let compra: String
    }

    static var disponivel: Bool { FileManager.default.fileExists(atPath: banco.path) }

    /// Os livros comprados, na ordem em que o banco os devolve.
    ///
    /// Conferido contra `bin/conciliar-kindle.py` em 29/10/2026: os 187
    /// registros sairam IDENTICOS campo a campo nos dois leitores.
    static func livros() throws -> [Livro] {
        guard disponivel else { throw Erro.semKindle }

        // O aplicativo mantem o banco aberto, com o diario em -wal. Abrir o
        // arquivo original seria ler uma versao sem as ultimas compras, e pior,
        // concorrer com quem escreve: copiamos os tres e lemos a copia.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("biblioteca-kindle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for sufixo in ["", "-wal", "-shm"] {
            let origem = URL(fileURLWithPath: banco.path + sufixo)
            if FileManager.default.fileExists(atPath: origem.path) {
                try? FileManager.default.copyItem(
                    at: origem, to: tmp.appendingPathComponent(origem.lastPathComponent))
            }
        }

        var db: OpaquePointer?
        let caminho = tmp.appendingPathComponent(banco.lastPathComponent).path
        guard sqlite3_open_v2(caminho, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); throw Erro.bancoIlegivel
        }
        defer { sqlite3_close(db) }

        var consulta: OpaquePointer?
        let sql = """
            select ZRAWBOOKTYPE, ZRAWPUBLICATIONDATE, ZSYNCMETADATAATTRIBUTES
            from ZBOOK where ZSYNCMETADATAATTRIBUTES is not null
            """
        guard sqlite3_prepare_v2(db, sql, -1, &consulta, nil) == SQLITE_OK else {
            throw Erro.bancoIlegivel
        }
        defer { sqlite3_finalize(consulta) }

        var achados: [Livro] = []
        while sqlite3_step(consulta) == SQLITE_ROW {
            guard sqlite3_column_int(consulta, 0) == tipoLivro,
                  let bytes = sqlite3_column_blob(consulta, 2) else { continue }
            let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(consulta, 2)))
            guard let attr = atributos(blob) else { continue }

            let asin = texto(attr["ASIN"])
            let titulo = texto(attr["title"])
            if asin.isEmpty || titulo.isEmpty { continue }

            // ZRAWPUBLICATIONDATE e epoch Unix PURO, nao Core Data. Lido com o
            // deslocamento do Core Data da 2056. Sem deslocamento da a
            // publicacao da EDICAO Kindle, que e a data que o usuario adotou
            // para o campo ano ("a data que eu utilizo nos livros tambem e a
            // data de publicacao").
            var ano = ""
            let pub = sqlite3_column_double(consulta, 1)
            if pub > 0, pub < 4_102_444_800 {       // ate o ano 2100
                ano = String(Calendar(identifier: .gregorian)
                    .component(.year, from: Date(timeIntervalSince1970: pub)))
            }
            achados.append(Livro(asin: asin, titulo: titulo,
                                 autor: primeiroAutor(attr["authors"]), ano: ano,
                                 compra: String(texto(attr["purchase_date"]).prefix(10))))
        }
        return achados
    }

    /// A capa, pelo endereco publico da Amazon.
    ///
    /// O Kindle TEM uma copia local das capas (Caches/covers), mas o nome do
    /// arquivo e um hash opaco: tentei em 29/10/2026 o MD5 e o SHA1 do ASIN, do
    /// ZBOOKID em cinco formas e do proprio endereco da imagem, e nenhuma das
    /// dezesseis combinacoes bateu com os 125 arquivos. O hash tambem nao
    /// aparece em lugar nenhum do container, entao e calculado a partir de algo
    /// que nao temos. Pelo endereco publico custa uma requisicao e funciona.
    ///
    /// `images-amazon.com` NAO resolve; `m.media-amazon.com` devolve 200 com a
    /// imagem — medido nos dois.
    static func capa(asin: String) -> Data? {
        guard let url = URL(string:
            "https://m.media-amazon.com/images/P/\(asin).01._SCLZZZZZZZ_.jpg") else { return nil }
        var pedido = URLRequest(url: url)
        pedido.timeoutInterval = 12
        var dados: Data?
        let espera = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: pedido) { d, resposta, _ in
            defer { espera.signal() }
            guard let d, (resposta as? HTTPURLResponse)?.statusCode == 200 else { return }
            // Livro sem capa devolve um retangulo cinza minusculo, com 200. O
            // tamanho e o que separa a capa de verdade do carimbo de ausencia.
            if d.count >= 2048 { dados = d }
        }.resume()
        _ = espera.wait(timeout: .now() + 15)
        return dados
    }

    enum Erro: Error { case semKindle, bancoIlegivel }

    // MARK: - O bplist do Kindle

    /// A raiz do arquivo e uma classe DO KINDLE, `SyncMetadataAttributes`, e os
    /// campos ficam sob a chave `attributes`. Declarar uma classe Objective-C
    /// com o mesmo nome faz o desarquivador encontra-la pelo runtime — sem API
    /// privada e sem andar pelos UID a mao.
    ///
    /// ARMADILHA: ZDISPLAYAUTHOR, ZSORTAUTHOR e ZALTERNATESORTAUTHOR sao blobs
    /// CIFRADOS e saem como lixo binario. O autor em texto claro so existe
    /// aqui dentro.
    private static func atributos(_ blob: Data) -> NSDictionary? {
        guard let desarquivador = try? NSKeyedUnarchiver(forReadingFrom: blob) else { return nil }
        desarquivador.requiresSecureCoding = false
        desarquivador.decodingFailurePolicy = .setErrorAndReturn
        let raiz = desarquivador.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        desarquivador.finishDecoding()
        return (raiz as? SyncMetadataAttributes)?.attributes ?? (raiz as? NSDictionary)
    }

    private static func texto(_ o: Any?) -> String {
        ((o as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `authors` vem em forma variada: texto, dicionario, lista, lista de
    /// dicionario, lista de lista. Procurar fundo e devolver o primeiro nome.
    private static func primeiroAutor(_ o: Any?) -> String {
        if let s = o as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let d = o as? NSDictionary {
            for chave in ["author", "name"] {
                let achado = primeiroAutor(d[chave])
                if !achado.isEmpty { return achado }
            }
            return ""
        }
        if let a = o as? NSArray {
            for x in a {
                let achado = primeiroAutor(x)
                if !achado.isEmpty { return achado }
            }
        }
        return ""
    }
}

/// A classe que o arquivo do Kindle nomeia. So sabe ler o campo que importa.
@objc(SyncMetadataAttributes)
final class SyncMetadataAttributes: NSObject, NSCoding {
    let attributes: NSDictionary?
    required init?(coder: NSCoder) {
        attributes = coder.decodeObject(forKey: "attributes") as? NSDictionary
        super.init()
    }
    func encode(with coder: NSCoder) {}     // so lemos; nunca gravamos no Kindle
}
