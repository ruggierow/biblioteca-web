import Foundation
import SQLite3

/// Le a biblioteca do Audible instalada neste Mac.
///
/// O Audible e um aplicativo de iPhone rodando no Apple Silicon, entao mora em
/// `/Applications/Audible.app/Wrapper/Audible.app`. A biblioteca e um SQLite
/// comum — texto claro e JSON, sem NSKeyedArchiver — bem mais facil que o do
/// Kindle:
///
///     ~/Library/Containers/com.audible.iphone/Data/Library/
///         Application Support/amzn1.account.<conta>-BR-library.sqlite
///
/// Ha um `anonymous-*.sqlite` ao lado: e a sessao SEM conta, nunca e esse.
///
/// A ARMADILHA, e ela e grande: `products` NAO E A BIBLIOTECA. E o cache de
/// catalogo — tudo que passou pela tela do aplicativo, 186 linhas em
/// 31/10/2026, quando a biblioteca de verdade tinha 3. Quem separa:
///
///     library_item                                     esta na sua biblioteca
///     user_products.customerEntitlements_
///         consumableIndefinitely = 1                   comprado, seu para sempre
///         consumable             = 1                   incluso no plano: acesso
///     tudo 0                                           nenhum direito: e pago
///
/// Este leitor entrega os tres sinais e NAO decide nada: quem decide quem entra
/// e a pagina, que e onde a base esta. A regra e do usuario (31/10/2026): entra
/// o que esta na biblioteca dele, ou o que ja esta catalogado e e gratuito pelo
/// plano.
///
/// Conferido contra `bin/conciliar-audible.py`: ver `bin/conferir-audible.py`,
/// que tranca as mesmas regras do lado do Python.
enum Audible {

    static let pasta = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Containers/com.audible.iphone/Data/Library/Application Support")

    static let aplicativo = "/Applications/Audible.app"

    static var instalado: Bool { FileManager.default.fileExists(atPath: aplicativo) }

    /// Em que pe esta o Audible neste Mac.
    ///
    /// As TRES faltas sao diferentes e levam a consertos diferentes, entao nao
    /// podem virar um "nao deu certo" so. A terceira e a mais traicoeira: o
    /// container do Audible e protegido pelo TCC, e um aplicativo sem Acesso
    /// Total ao Disco nao consegue nem LISTAR a pasta — o sintoma e igualzinho
    /// ao de quem nunca entrou na conta. Dizer "entre na sua conta" nesse caso
    /// mandaria o usuario fazer o que ja fez.
    enum Estado {
        case pronto(URL)
        case semAplicativo
        case semConta
        case semPermissao
    }

    static var estado: Estado {
        let nomes: [String]
        do {
            nomes = try FileManager.default.contentsOfDirectory(atPath: pasta.path)
        } catch {
            let e = error as NSError
            let barrado = e.domain == NSCocoaErrorDomain
                && (e.code == NSFileReadNoPermissionError || e.code == NSFileReadUnknownError)
            if barrado { return .semPermissao }
            return instalado ? .semConta : .semAplicativo
        }
        let achado = nomes
            .filter { $0.hasPrefix("amzn1.account.") && $0.hasSuffix("-BR-library.sqlite") }
            .sorted().first
        if let achado { return .pronto(pasta.appendingPathComponent(achado)) }
        return instalado ? .semConta : .semAplicativo
    }

    /// O banco DA CONTA. Nome variavel, porque traz o identificador dela.
    static var banco: URL? {
        if case .pronto(let url) = estado { return url }
        return nil
    }

    static var disponivel: Bool { banco != nil }

    /// A frase que explica a falta, ou nada quando nao ha falta.
    static var motivoDaFalta: String? {
        switch estado {
        case .pronto:
            return nil
        case .semAplicativo:
            return "Nao achei o aplicativo Audible neste Mac. "
                 + "Instale-o pela App Store e entre na sua conta para os audiolivros aparecerem aqui."
        case .semConta:
            return "O Audible esta instalado, mas ainda nao entrou na sua conta neste Mac — "
                 + "nao ha biblioteca para ler. Abra o Audible, entre na conta e tente de novo."
        case .semPermissao:
            return "Nao consegui abrir a pasta do Audible: falta autorizar este aplicativo em "
                 + "Ajustes do Sistema, Privacidade e Seguranca, Acesso Total ao Disco."
        }
    }

    struct Livro {
        let asin: String
        let titulo: String
        let autores: [String]
        let narradores: [String]
        let anoAudio: String
        let naBiblioteca: Bool
        let consumivel: Bool
        let paraSempre: Bool
    }

    /// Os audiolivros do cache, com os tres sinais de direito.
    ///
    /// So `contentType = "Product"`: os 38 `Show` sao podcasts, e podcast nao e
    /// livro (decisao do usuario, 30/10/2026).
    static func livros() throws -> [Livro] {
        guard let banco else { throw Erro.semAudible }

        // O aplicativo mantem o banco aberto, com o diario em -wal. Abrir o
        // arquivo original seria ler uma versao sem as ultimas adicoes, e pior,
        // concorrer com quem escreve: copiamos os tres e lemos a copia.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("biblioteca-audible-\(UUID().uuidString)")
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
            select p.asin, p.title, p.authors, p.narrators, p.releaseDate,
                   u.customerEntitlements_consumable,
                   u.customerEntitlements_consumableIndefinitely,
                   (select count(*) from library_item li where li.asin = p.asin)
            from products p left join user_products u on u.asin = p.asin
            where p.contentType = 'Product'
            """
        guard sqlite3_prepare_v2(db, sql, -1, &consulta, nil) == SQLITE_OK else {
            throw Erro.bancoIlegivel
        }
        defer { sqlite3_finalize(consulta) }

        var achados: [Livro] = []
        while sqlite3_step(consulta) == SQLITE_ROW {
            let asin = texto(consulta, 0)
            let titulo = texto(consulta, 1)
            if asin.isEmpty || titulo.isEmpty { continue }
            achados.append(Livro(
                asin: asin, titulo: titulo,
                autores: nomes(texto(consulta, 2)),
                narradores: nomes(texto(consulta, 3)),
                // O `releaseDate` e o lancamento do AUDIOLIVRO, nao da obra: ha
                // classicos com 2026. A pagina so o usa quando a obra nao esta
                // catalogada — e avisa na tela que foi isso que aconteceu.
                anoAudio: String(texto(consulta, 4).prefix(4)),
                naBiblioteca: sqlite3_column_int(consulta, 7) > 0,
                consumivel: sqlite3_column_int(consulta, 5) == 1,
                paraSempre: sqlite3_column_int(consulta, 6) == 1))
        }
        return achados
    }

    enum Erro: Error { case semAudible, bancoIlegivel }

    private static func texto(_ consulta: OpaquePointer?, _ coluna: Int32) -> String {
        guard let c = sqlite3_column_text(consulta, coluna) else { return "" }
        return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `authors` e `narrators` vem como JSON `[{"name":"..."}, ...]`.
    ///
    /// O campo de autor traz TRADUTOR dentro: 58 dos 126 titulos tinham dois ou
    /// mais nomes em 30/10/2026, e nem todos marcados. Quem fica com o primeiro
    /// e manda o resto para os comentarios e a pagina; aqui entregamos a lista
    /// inteira, na ordem em que o Audible a devolve.
    private static func nomes(_ json: String) -> [String] {
        guard let dados = json.data(using: .utf8),
              let lista = try? JSONSerialization.jsonObject(with: dados) as? [[String: Any]]
        else { return [] }
        return lista.compactMap {
            ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}
