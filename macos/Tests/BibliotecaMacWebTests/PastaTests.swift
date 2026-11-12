import XCTest
@testable import BibliotecaMacWeb

/// As duas funcoes do "Selecionar pasta" que mexem em arquivo.
///
/// So elas: o resto do fluxo -- os quatro ramos, os textos, a contagem -- e da
/// pagina, e esta medido em motor-web/testes/casos/11-selecionar-pasta.spec.js,
/// que roda os mesmos casos contra os DOIS hospedeiros. Estes aqui sao o par do
/// `cargo test` do Rust do Windows, caso a caso, porque o mesmo botao nao pode
/// fazer coisas diferentes nos dois aplicativos.
///
/// Nenhum deles toca no UserDefaults da maquina: `criarArquivoNaPasta` foi
/// separado do `definirPasta` exatamente por isso.
final class PastaTests: XCTestCase {

    /// Uma pasta vazia so para este teste, apagada no fim.
    private func pastaDeTeste(_ nome: String) -> URL {
        let p = FileManager.default.temporaryDirectory
            .appendingPathComponent("biblioteca-teste-\(nome)-\(getpid())")
        try? FileManager.default.removeItem(at: p)
        try! FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: p) }
        return p
    }

    func testPastaVaziaNaoTemArquivoENaoTemErro() {
        let r = olharAPasta(pastaDeTeste("vazia"))
        XCTAssertEqual(r["temArquivo"] as? Bool, false)
        XCTAssertEqual(r["erro"] as? String, "")
        XCTAssertEqual(r["conteudo"] as? String, "")
    }

    func testPastaComArquivoDevolveOConteudoInteiro() throws {
        let p = pastaDeTeste("comlivros")
        let tsv = "Titulo\tAutor\tTema\t2020\tEstante\n"
        try tsv.write(to: p.appendingPathComponent("biblioteca.txt"), atomically: true, encoding: .utf8)
        let r = olharAPasta(p)
        XCTAssertEqual(r["temArquivo"] as? Bool, true)
        XCTAssertEqual(r["erro"] as? String, "")
        // O CONTEUDO, byte a byte: quem conta os livros e a parseTSV da pagina.
        XCTAssertEqual(r["conteudo"] as? String, tsv)
        XCTAssertEqual(r["nome"] as? String, p.lastPathComponent)
    }

    func testBibliotecaQueEPastaDaErroENaoPerdeOQueEstaLa() throws {
        // O ramo C. Um diretorio chamado biblioteca.txt existe, entao ha
        // "arquivo" no caminho -- so nao da para ler. O certo e avisar.
        let p = pastaDeTeste("quebrada")
        let falso = p.appendingPathComponent("biblioteca.txt")
        try FileManager.default.createDirectory(at: falso, withIntermediateDirectories: true)
        let r = olharAPasta(p)
        XCTAssertEqual(r["temArquivo"] as? Bool, true)
        XCTAssertNotEqual(r["erro"] as? String, "")
        // E criar nao pode passar por cima.
        XCTAssertThrowsError(try criarArquivoNaPasta(p, conteudo: "x")) { erro in
            XCTAssertEqual(erro as? ErroDePasta, .mensagem("ja_existe"))
        }
        var ehPasta = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: falso.path, isDirectory: &ehPasta))
        XCTAssertTrue(ehPasta.boolValue)
    }

    func testPastaQueNaoExisteDaErroNosDois() {
        let p = FileManager.default.temporaryDirectory
            .appendingPathComponent("biblioteca-teste-inexistente-nunca-criada")
        try? FileManager.default.removeItem(at: p)
        XCTAssertNotEqual(olharAPasta(p)["erro"] as? String, "")
        XCTAssertThrowsError(try criarArquivoNaPasta(p, conteudo: ""))
    }

    func testCriarGravaOConteudoEVazioEVazio() throws {
        let p = pastaDeTeste("criar")
        let arq = try criarArquivoNaPasta(p, conteudo: "")
        XCTAssertEqual(try String(contentsOf: arq, encoding: .utf8), "")

        let q = pastaDeTeste("criar-com-livros")
        let tsv = "Levado\tAutor\tTema\t1999\tEstante\n"
        let arq2 = try criarArquivoNaPasta(q, conteudo: tsv)
        XCTAssertEqual(try String(contentsOf: arq2, encoding: .utf8), tsv)
    }

    func testCriarNuncaSobrescreveBibliotecaExistente() throws {
        // A corrida: o arquivo apareceu entre o olhar e o criar. O iCloud baixa
        // renomeando e troca os dois depois.
        let p = pastaDeTeste("corrida")
        let arq = p.appendingPathComponent("biblioteca.txt")
        try "o que ja estava la".write(to: arq, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try criarArquivoNaPasta(p, conteudo: "")) { erro in
            XCTAssertEqual(erro as? ErroDePasta, .mensagem("ja_existe"))
        }
        XCTAssertEqual(try String(contentsOf: arq, encoding: .utf8), "o que ja estava la")
    }
}
