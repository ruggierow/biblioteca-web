import AppKit
import WebKit

// App macOS nativo com WKWebView.
// Lê e grava biblioteca.txt direto no iCloud Drive sem depender do Chrome.
// O HTML envia o TSV via webkit.messageHandlers.exportar a cada salvar().

@main
struct BibliotecaWebApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
        
    private var janela: NSWindow!
    private var webView: WKWebView!
    private let impressor = ImpressorDeHTML()
    private var gravarTimer: Timer?
    private var gravarDatTimer: Timer?

    // MARK: - Onde ficam os arquivos
    //
    // Ate a 1.9.20 o caminho era CRAVADO no iCloud Drive e nao havia como
    // muda-lo: quem guarda os livros noutro lugar -- um disco externo, uma
    // pasta do Dropbox, o Mac sem iCloud ligado -- simplesmente nao tinha
    // aplicativo. Agora a pasta e escolhida pelo botao "Selecionar pasta", e o
    // iCloud continua sendo o padrao: quem nunca escolheu nada nao percebe
    // diferenca nenhuma.

    /// A chave no UserDefaults. O aplicativo NAO e em caixa de areia (veja o
    /// .entitlements: so `network.client`), entao guardar o caminho em texto
    /// basta -- nao precisa de marcador com escopo de seguranca como no iPhone.
    private static let chaveDaPasta = "bibliotecaPasta"

    /// A pasta do iCloud Drive, que e o padrao de quem nunca escolheu nada.
    private var pastaPadrao: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Biblioteca")
    }

    /// A pasta em uso: a escolhida, se ainda existir, senao a do iCloud.
    ///
    /// O "se ainda existir" nao e zelo: um disco externo desmontado ou uma
    /// pasta em rede fora do ar fariam o aplicativo gravar num caminho morto.
    /// Voltar ao padrao e visivel -- a faixa mostra o caminho -- e reversivel.
    private var pastaDeDados: URL {
        if let texto = UserDefaults.standard.string(forKey: Self.chaveDaPasta), !texto.isEmpty {
            var pasta = ObjCBool(false)
            if FileManager.default.fileExists(atPath: texto, isDirectory: &pasta), pasta.boolValue {
                return URL(fileURLWithPath: texto, isDirectory: true)
            }
        }
        return pastaPadrao
    }

    private var arquivoDaBiblioteca: URL { pastaDeDados.appendingPathComponent("biblioteca.txt") }
    private var arquivoDasCapas: URL { pastaDeDados.appendingPathComponent("biblioteca.dat") }

    // MARK: - Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()

        // Pontes nativas
        config.userContentController.add(self, name: "exportar")
        config.userContentController.add(self, name: "fotos")
        config.userContentController.add(self, name: "fechar")
        config.userContentController.add(self, name: "backup")
        config.userContentController.add(self, name: "recarregar")
        config.userContentController.add(self, name: "fotosRemovidas")
        config.userContentController.add(self, name: "fotosReadicionadas")
        config.userContentController.add(self, name: "imprimir")
        config.userContentController.add(self, name: "salvarArquivo")
        config.userContentController.add(self, name: "copiar")
        config.userContentController.add(self, name: "grupos")
        config.userContentController.add(self, name: "kindleListar")
        config.userContentController.add(self, name: "kindleCapas")
        config.userContentController.add(self, name: "audibleListar")

        // "Selecionar pasta" e o unico canal que RESPONDE. Os outros sao de mao
        // unica -- a pagina avisa e segue -- mas aqui cada passo depende da
        // resposta do anterior: o que ha na pasta decide qual pergunta fazer.
        // `addScriptMessageHandler` devolve uma Promessa do lado do JavaScript,
        // o que dispensa o vaivem de chamar uma funcao global da pagina de
        // volta -- e dispensa o estado pendurado que isso exigiria.
        config.userContentController.addScriptMessageHandler(
            self, contentWorld: .page, name: "pasta")

        // Injeta __BIBLIOTECA_NATIVE__ e o caminho real do arquivo antes do HTML
        // executar qualquer script. O caminho aparece no banner de sincronização,
        // igual ao que o app do Windows mostra — ajuda a diagnosticar quando os
        // dois lados não estão apontando para o mesmo arquivo.
        let caminhoJS = Self.paraLiteralJS(arquivoDaBiblioteca.path)
        let flagNativa = WKUserScript(
            source: """
            window.__BIBLIOTECA_NATIVE__ = true;
            window.__BIBLIOTECA_CAMINHO__ = \(caminhoJS);
            window.__BIBLIOTECA_KINDLE__ = \(Kindle.disponivel ? "true" : "false");
            window.__BIBLIOTECA_AUDIBLE__ = \(Audible.disponivel ? "true" : "false");
            window.__BIBLIOTECA_LOJAS_AVISO__ = \(Self.paraLiteralJS(Audible.motivoDaFalta ?? ""));
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(flagNativa)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        // Sem isto, `confirm()` devolve FALSE na hora e `alert()` nao aparece —
        // sem erro, sem diálogo, sem pista. Era por isso que o botao Remover da
        // lista nao fazia nada no Mac: ele pergunta antes de apagar, a resposta
        // vinha falsa, e o `if` nunca entrava. Medido em 12/10/2026.
        webView.uiDelegate = self

        janela = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        janela.title = "Biblioteca"
        janela.contentView = webView
        janela.center()
        janela.makeKeyAndOrderFront(nil)

        guard let htmlURL = Bundle.main.url(forResource: "biblioteca", withExtension: "html") else {
            alerta("O arquivo biblioteca.html não foi encontrado no bundle do app.")
            return
        }
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())

        configurarMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Carregar do iCloud

    private func carregarDoICloud() {
        let url = arquivoDaBiblioteca
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else { return } // arquivo ainda não existe

        // Dispara download caso o arquivo esteja somente na nuvem
        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .some(.notDownloaded) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.carregarDoICloud() }
            return
        }

        do {
            let conteudo = try String(contentsOf: url, encoding: .utf8)
            injetarConteudo(conteudo)
        } catch {
            alerta("Erro ao ler biblioteca.txt do iCloud:\n\(error.localizedDescription)")
        }
    }

    private func injetarConteudo(_ tsv: String) {
        let escapado = tsv
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let js = """
        (function() {
            try {
                var importados = parseTSV(`\(escapado)`);
                biblioteca = importados;
                localStorage.setItem("biblioteca-livros", JSON.stringify(biblioteca));
                paginaAtual = 1;
                atualizarTudo();
                atualizarBannerSync('ok');
            } catch(e) { console.error('Erro ao injetar:', e); }
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error { print("Erro ao injetar conteúdo:", error) }
        }
    }

    // MARK: - Carregar fotos do iCloud

    /// Diz à página o que está acontecendo. É barato e roda ANTES do trabalho
    /// pesado: o WKWebView desenha noutro processo, então a mensagem aparece
    /// mesmo com a linha principal deste app travada logo em seguida.
    private func avisarCarregando(_ detalhe: String) {
        let limpo = detalhe.replacingOccurrences(of: "`", with: "'")
        webView.evaluateJavaScript(
            "if (typeof mostrarCarregando === 'function') mostrarCarregando(`\(limpo)`);")
    }

    private func pararAviso() {
        webView.evaluateJavaScript(
            "if (typeof esconderCarregando === 'function') esconderCarregando();")
    }

    private func carregarFotosDoICloud() {
        let url = arquivoDasCapas
        let fm = FileManager.default

        // Se biblioteca.dat ainda não existe, exporta o localStorage atual para criá-lo
        guard fm.fileExists(atPath: url.path) else {
            pararAviso()
            exportarLocalStorageParaICloud()
            return
        }

        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .some(.notDownloaded) {
            avisarCarregando("Baixando as capas do iCloud. O arquivo ainda não está neste Mac.")
            try? fm.startDownloadingUbiquitousItem(at: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.carregarFotosDoICloud() }
            return
        }

        // O tamanho sai dos atributos do arquivo: é instantâneo, e transforma
        // uma espera muda numa espera explicada.
        let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        let medida = ByteCountFormatter.string(fromByteCount: Int64(bytes ?? 0), countStyle: .file)
        avisarCarregando(bytes == nil
            ? "Carregando as capas dos livros."
            : "Carregando as capas dos livros — \(medida). Isto leva alguns segundos.")

        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            injetarFotos(json)
            // Após mesclar o dat no localStorage, exporta de volta para o iCloud.
            // Garante que fotos que só existiam no localStorage do Mac (antes do
            // sync existir) cheguem ao biblioteca.dat e portanto ao iPhone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.exportarLocalStorageParaICloud()
            }
        } catch {
            print("Erro ao ler biblioteca.dat:", error)
            pararAviso()
        }
    }

    /// Lê as fotos que já estão no localStorage do WKWebView e grava em biblioteca.dat.
    /// Chamado quando biblioteca.dat ainda não existe OU pelo item de menu.
    private func exportarLocalStorageParaICloud() {
        // Lê da variável `fotos` em memória, NÃO do localStorage: desde que as
        // fotos deixaram de ser duplicadas lá, o localStorage pode estar vazio
        // enquanto a memória tem tudo. Cai no localStorage só como retaguarda.
        let js = """
        (function() {
            try {
                var f = (typeof fotos === 'object' && fotos) ? fotos : null;
                if (!f || Object.keys(f).length === 0) {
                    var raw = localStorage.getItem("biblioteca-fotos");
                    f = raw ? JSON.parse(raw) : {};
                }
                return JSON.stringify({ total: Object.keys(f).length, dados: f });
            } catch(e) { return JSON.stringify({ total: -1, erro: String(e) }); }
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error = error {
                print("Erro evaluateJavaScript:", error)
                return
            }
            guard let json = result as? String else {
                print("exportarFotos: resultado não é String:", result ?? "nil")
                return
            }
            print("exportarFotos localStorage:", json.prefix(200))

            // Extrai apenas o dict de fotos para gravar
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let total = obj["total"] as? Int,
                  total > 0,
                  let fotos = obj["dados"] else {
                print("exportarFotos: nenhuma foto encontrada no localStorage")
                return
            }
            guard let fotosData = try? JSONSerialization.data(withJSONObject: fotos),
                  let fotosJSON = String(data: fotosData, encoding: .utf8) else { return }
            self.gravarDatNoICloud(fotosJSON)
        }
    }

    /// Manda o registro de exclusoes para a pagina ANTES das fotos. Sem ele a
    /// mescla do HTML nao tem como saber o que foi apagado, e a capa volta.
    /// Pergunta onde gravar e grava. So avisa a pagina DEPOIS de escrever: o
    /// caminho antigo (download por blob dentro do WKWebView) nao escrevia nada
    /// e mesmo assim anunciava "Planilha salva em ~/Downloads".
    private func salvarArquivoEscolhendoPasta(nome: String, conteudo: Data) {
        let painel = NSSavePanel()
        painel.nameFieldStringValue = nome
        painel.canCreateDirectories = true
        painel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        painel.begin { [weak self] resposta in
            guard resposta == .OK, let destino = painel.url else { return }   // cancelou: nada a dizer
            do {
                try conteudo.write(to: destino, options: .atomic)
                self?.avisarNaPagina("Planilha salva em \(destino.path)")
            } catch {
                self?.avisarNaPagina("Nao foi possivel salvar: \(error.localizedDescription)")
            }
        }
    }

    private func avisarNaPagina(_ texto: String) {
        let escapado = texto
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        webView.evaluateJavaScript("if (typeof toast === 'function') toast(`\(escapado)`, 6000);")
    }

    private func injetarRegistroDeRemocoes() {
        let reg = lerRegistro()
        guard let dados = try? JSONSerialization.data(withJSONObject: reg),
              let json = String(data: dados, encoding: .utf8) else { return }
        let escapado = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let js = """
        (function() {
            try {
                if (typeof receberRemocoes === 'function') receberRemocoes(`\(escapado)`);
            } catch(e) { console.error('Erro ao injetar registro de remocoes:', e); }
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error { print("Erro ao injetar registro:", error) }
        }
    }

    /// Tira ids do registro — a capa foi reposta, entao ela pode voltar a viajar.
    private func cancelarRemocoes(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var reg = lerRegistro()
        var mudou = false
        for id in ids where reg.removeValue(forKey: id) != nil { mudou = true }
        guard mudou else { return }
        guard let dados = try? JSONSerialization.data(
            withJSONObject: reg, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: pastaDeDados, withIntermediateDirectories: true)
        do {
            try dados.write(to: registroURL, options: .atomic)
        } catch {
            print("registro de exclusões: falha ao gravar:", error)
        }
    }

    private func injetarFotos(_ json: String) {
        injetarRegistroDeRemocoes()
        let escapado = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        // A mescla e a decisão de guardar (ou não) no localStorage ficam do lado
        // do HTML, em receberFotosDoArquivo() — um lugar só, compartilhado com o
        // app do Windows. Antes isto duplicava as fotos no localStorage: 9,2 MB
        // repetindo o que já estava no biblioteca.dat.
        let js = """
        (function() {
            try {
                if (typeof receberFotosDoArquivo === 'function') {
                    receberFotosDoArquivo(`\(escapado)`);
                } else {
                    // HTML antigo, sem a função: mantém o comportamento anterior
                    var novasFotos = JSON.parse(`\(escapado)`);
                    fotos = Object.assign({}, fotos, novasFotos);
                    if (typeof atualizarTudo === 'function') atualizarTudo();
                }
            } catch(e) { console.error('Erro ao injetar fotos:', e); }
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error { print("Erro ao injetar fotos:", error) }
        }
    }

    // MARK: - Gravar fotos no iCloud (debounce 1 s)

    /// Fila SERIAL para tudo que toca o `biblioteca.dat`.
    ///
    /// O timer dispara na linha principal, e era ali mesmo que o backup
    /// automático e a gravação aconteciam — com o arquivo passando de 39 MB.
    /// O backup sozinho já lê o arquivo inteiro, lê o backup anterior e
    /// compara os dois. A janela congelava um segundo depois de cada mudança
    /// de capa, e também no arranque, sem dizer nada.
    ///
    /// Sendo serial, ela também impede que duas gravações do mesmo arquivo se
    /// cruzem.
    private let filaDat = DispatchQueue(label: "biblioteca.dat", qos: .utility)

    private func agendarGravacaoDat(_ json: String) {
        gravarDatTimer?.invalidate()
        // O timer continua no run loop principal — é só o amortecedor de 1 s,
        // e não custa nada. O trabalho é que sai de lá.
        gravarDatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.filaDat.async { self.gravarDatNoICloud(json) }
        }
    }

    /// Roda na `filaDat`, nunca na linha principal: não pode tocar a tela a não
    /// ser voltando para a fila principal, como faz o alerta de erro abaixo.
    private func gravarDatNoICloud(_ json: String) {
        let url = arquivoDasCapas
        backupAutomatico(url, maximo: maxBackupDat, feito: &backupDatFeito)
        print("gravarDat: gravando em", url.path, "(\(json.count) bytes)")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try json.write(to: url, atomically: true, encoding: .utf8)
            print("gravarDat: sucesso")
        } catch {
            print("gravarDat: ERRO:", error)
            DispatchQueue.main.async {
                self.alerta("Erro ao gravar fotos no iCloud:\n\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Gravar no iCloud (debounce 500 ms para não gravar a cada tecla)

    private func agendarGravacao(_ conteudo: String) {
        gravarTimer?.invalidate()
        gravarTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.gravarNoICloud(conteudo)
        }
    }

    private func gravarNoICloud(_ conteudo: String) {
        let url = arquivoDaBiblioteca
        backupAutomatico(url, maximo: maxBackupTxt, feito: &backupTxtFeito)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try conteudo.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            DispatchQueue.main.async {
                self.alerta("Erro ao gravar no iCloud:\n\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Menu

    private func configurarMenu() {
        let menuBar = NSMenu()

        let appItem = NSMenuItem()
        menuBar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Sobre Biblioteca",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Sair",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu

        let arquivoItem = NSMenuItem()
        menuBar.addItem(arquivoItem)
        let arquivoMenu = NSMenu(title: "Arquivo")
        let itemRecarregar = NSMenuItem(title: "Recarregar",
                                        action: #selector(recarregarDoICloud),
                                        keyEquivalent: "r")
        itemRecarregar.target = self
        arquivoMenu.addItem(itemRecarregar)

        let itemExportarFotos = NSMenuItem(title: "Exportar as capas",
                                           action: #selector(exportarFotosManualmente),
                                           keyEquivalent: "")
        itemExportarFotos.target = self
        arquivoMenu.addItem(itemExportarFotos)

        arquivoItem.submenu = arquivoMenu

        NSApp.mainMenu = menuBar
    }

    @objc private func recarregarDoICloud() {
        carregarDoICloud()
        carregarFotosDoICloud()
    }

    @objc private func exportarFotosManualmente() {
        exportarLocalStorageParaICloud()
    }

    // MARK: - Registro de exclusões de capas
    //
    // As capas viajam pelo biblioteca.dat e cada aparelho MESCLA o que tem com o
    // que está no arquivo — e mesclagem só sabe somar. Sem este registro, uma
    // capa apagada aqui volta na sincronização seguinte do iPhone, que ainda a
    // tem. Contrato em comum/exclusao-de-fotos.md.

    private var registroURL: URL { pastaDeDados.appendingPathComponent("biblioteca-removidas.json") }

    private func registrarRemocoes(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var reg = lerRegistro()
        let agora = Self.carimbo.string(from: Date())
        for id in ids { reg[id] = agora }
        guard let dados = try? JSONSerialization.data(
            withJSONObject: reg, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: pastaDeDados, withIntermediateDirectories: true)
        do {
            try dados.write(to: registroURL, options: .atomic)
        } catch {
            print("registro de exclusões: falha ao gravar:", error)
        }
    }

    // MARK: - Nomes dos grupos de literatura
    //
    // O biblioteca.txt guarda so os NUMEROS dos grupos na coluna 8 ("1;3"); os
    // nomes ficam no localStorage do navegador, que nao sai daqui. Sem este
    // arquivo, o iPhone mostra "Grupo 2" onde aqui se le "Clube da Tarde", e o
    // Windows nem ve os nomes dados no Mac.

    private var gruposURL: URL { pastaDeDados.appendingPathComponent("grupos.json") }

    private func gravarGrupos(_ json: String) {
        guard let dados = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: dados)) != nil
        else { return }
        // O HTML publica a cada abertura; nao vale sujar o iCloud sem mudanca.
        if let atual = try? Data(contentsOf: gruposURL), atual == dados { return }
        try? FileManager.default.createDirectory(at: pastaDeDados, withIntermediateDirectories: true)
        do {
            try dados.write(to: gruposURL, options: .atomic)
        } catch {
            print("grupos: falha ao gravar:", error)
        }
    }

    private func lerRegistro() -> [String: String] {
        guard let dados = try? Data(contentsOf: registroURL),
              let reg = try? JSONSerialization.jsonObject(with: dados) as? [String: String]
        else { return [:] }
        // Entradas com mais de 90 dias saem: passado esse prazo, qualquer
        // aparelho que ainda tivesse a capa já teria sincronizado.
        let limite = Date().addingTimeInterval(-90 * 86_400)
        return reg.filter { (Self.carimbo.date(from: $0.value) ?? .distantPast) > limite }
    }

    private static let carimbo: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Backup automático
    //
    // Copia o arquivo ANTES da primeira gravação da sessão, preservando o último
    // estado bom. No fim da sessão seria tarde: se o app travar ou faltar energia
    // não há encerramento — e um backup do que se está deixando é justamente o
    // que já está no arquivo.
    //
    // Só copia se o conteúdo MUDOU em relação ao backup mais recente. Isso é
    // essencial aqui: este app reescreve o .dat toda vez que abre, então um
    // gatilho por data de modificação geraria 9 MB de backup a cada abertura.

    private let maxBackupTxt = 30
    private let maxBackupDat = 7
    private var backupTxtFeito = false
    private var backupDatFeito = false

    /// Carimbo do início da sessão — o backup guarda o estado em que ela começou.
    private lazy var sufixoSessao: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH'h'mm"
        return f.string(from: Date())
    }()

    private func backupAutomatico(_ arquivo: URL, maximo: Int, feito: inout Bool) {
        guard !feito else { return }
        feito = true   // marca antes de tentar: se falhar, não insiste a cada gravação

        let fm = FileManager.default
        guard fm.fileExists(atPath: arquivo.path),
              let atual = try? Data(contentsOf: arquivo) else { return }

        let pasta = arquivo.deletingLastPathComponent().appendingPathComponent("Backups")
        let base = arquivo.deletingPathExtension().lastPathComponent
        let ext = arquivo.pathExtension
        let prefixo = base + "_"

        let anteriores = ((try? fm.contentsOfDirectory(at: pasta,
                                                       includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefixo) && $0.pathExtension == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Nada mudou desde o último backup: não duplica.
        if let ultimo = anteriores.last,
           let anterior = try? Data(contentsOf: ultimo),
           anterior == atual {
            return
        }

        try? fm.createDirectory(at: pasta, withIntermediateDirectories: true)
        let destino = pasta.appendingPathComponent("\(prefixo)\(sufixoSessao).\(ext)")
        do {
            try atual.write(to: destino, options: .atomic)
        } catch {
            print("backup automático falhou:", error)
            return
        }

        // Rotação: mantém os `maximo` mais recentes. Os nomes trazem a data em
        // AAAA-MM-DD_HHhMM, que ordena igual cronologicamente.
        var todos = anteriores
        todos.append(destino)
        if todos.count > maximo {
            for antigo in todos.prefix(todos.count - maximo) {
                try? fm.removeItem(at: antigo)
            }
        }
    }

    // MARK: - Backup nativo

    /// Copia biblioteca.txt para biblioteca_<sufixo>.txt na MESMA pasta do iCloud.
    /// Antes disso o botão Backup do Mac caía no último recurso do HTML e baixava
    /// o arquivo para a pasta Downloads — comportamento diferente do Windows,
    /// que sempre salvou ao lado do original.
    private func fazerBackup(_ sufixo: String) {
        let origem = arquivoDaBiblioteca
        let fm = FileManager.default

        guard fm.fileExists(atPath: origem.path) else {
            avisarNoHTML("Backup: biblioteca.txt não encontrado no iCloud.")
            return
        }
        let destino = origem.deletingLastPathComponent()
            .appendingPathComponent("biblioteca_\(sufixo).txt")
        do {
            if fm.fileExists(atPath: destino.path) {
                try fm.removeItem(at: destino)
            }
            try fm.copyItem(at: origem, to: destino)
            avisarNoHTML("Backup salvo: \(destino.lastPathComponent)")
        } catch {
            avisarNoHTML("Erro no backup: \(error.localizedDescription)")
        }
    }

    // MARK: - Utilitário

    /// Converte uma String Swift num literal JavaScript seguro (com aspas).
    // MARK: - Kindle

    /// Devolve a biblioteca do Kindle para a pagina decidir o que e novo.
    ///
    /// Quem compara e a PAGINA, nao este lado: a base esta la, ja carregada e
    /// ja com as regras de duplicata. Mandar o banco inteiro (116 livros, uns
    /// 20 KB) e mais simples e mais barato que ensinar o Swift a ler TSV.
    private func responderKindleListar() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var carga: [String: Any]
            do {
                let livros = try Kindle.livros()
                carga = ["ok": true, "livros": livros.map {
                    ["asin": $0.asin, "titulo": $0.titulo, "autor": $0.autor,
                     "ano": $0.ano, "compra": $0.compra]
                }]
            } catch Kindle.Erro.semKindle {
                carga = ["ok": false, "erro": "Nao achei a biblioteca do Kindle neste Mac. "
                                            + "O aplicativo Kindle precisa estar instalado e "
                                            + "ter sincronizado ao menos uma vez."]
            } catch {
                carga = ["ok": false, "erro": "Nao consegui ler a biblioteca do Kindle."]
            }
            self?.entregar(carga, para: "kindleRecebeLista")
        }
    }

    // MARK: - Audible

    /// Devolve a biblioteca do Audible para a pagina decidir o que e novo.
    ///
    /// Mesmo desenho do Kindle: quem compara e a PAGINA, que e onde a base
    /// esta. Este lado entrega os tres sinais de direito e nao decide nada.
    ///
    /// A mensagem de falta vem do proprio `Audible`, e distingue "nao esta
    /// instalado" de "esta instalado mas nao entrou na conta" — sao conservas
    /// diferentes, e dizer so "nao consegui" obrigaria o usuario a adivinhar.
    private func responderAudibleListar() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var carga: [String: Any]
            do {
                let livros = try Audible.livros()
                carga = ["ok": true, "livros": livros.map {
                    ["asin": $0.asin, "titulo": $0.titulo, "autores": $0.autores,
                     "narradores": $0.narradores, "anoAudio": $0.anoAudio,
                     "naBiblioteca": $0.naBiblioteca, "consumivel": $0.consumivel,
                     "paraSempre": $0.paraSempre]
                }]
            } catch Audible.Erro.semAudible {
                carga = ["ok": false,
                         "erro": Audible.motivoDaFalta
                               ?? "Nao achei a biblioteca do Audible neste Mac."]
            } catch {
                carga = ["ok": false, "erro": "Nao consegui ler a biblioteca do Audible."]
            }
            self?.entregar(carga, para: "audibleRecebeLista")
        }
    }

    /// Baixa as capas dos livros que o usuario confirmou.
    ///
    /// Quem baixa e este lado, nao a pagina: o endereco da Amazon nao manda
    /// cabecalho de CORS, entao um `fetch` de dentro do WKWebView seria
    /// recusado pelo navegador. Aqui nao ha essa barreira.
    private func responderKindleCapas(_ json: String) {
        guard let dados = json.data(using: .utf8),
              let asins = try? JSONSerialization.jsonObject(with: dados) as? [String]
        else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var capas: [String: String] = [:]
            for asin in asins.prefix(60) {
                if let imagem = Kindle.capa(asin: asin) {
                    capas[asin] = "data:image/jpeg;base64," + imagem.base64EncodedString()
                }
            }
            self?.entregar(["capas": capas], para: "kindleRecebeCapas")
        }
    }

    /// Manda um objeto para uma funcao da pagina, sempre na linha principal.
    private func entregar(_ carga: [String: Any], para funcao: String) {
        guard let dados = try? JSONSerialization.data(withJSONObject: carga),
              let json = String(data: dados, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(
                "if (typeof \(funcao) === 'function') \(funcao)(\(json));") { _, erro in
                if let erro { print("Erro ao entregar a \(funcao):", erro) }
            }
        }
    }

    private static func paraLiteralJS(_ texto: String) -> String {
        if let dados = try? JSONSerialization.data(withJSONObject: [texto]),
           let json = String(data: dados, encoding: .utf8),
           json.count > 2 {
            return String(json.dropFirst().dropLast())   // remove os colchetes do array
        }
        return "\"\""
    }

    /// Mostra uma mensagem usando o toast do próprio HTML, para o retorno das
    /// ações nativas aparecer no mesmo lugar que o das ações do Windows.
    private func avisarNoHTML(_ msg: String) {
        let literal = Self.paraLiteralJS(msg)
        let js = "if (typeof toast === 'function') { toast(\(literal), 4000); }"
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func alerta(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Biblioteca"
        a.informativeText = msg
        a.alertStyle = .critical
        a.runModal()
    }
}

// MARK: - WKNavigationDelegate

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        carregarDoICloud()
        carregarFotosDoICloud()
    }

    /// Entrega ao sistema o endereco que o usuario clicou.
    ///
    /// Sem isto o link nos comentarios nao fazia NADA — medido reproduzindo este
    /// WKWebView: um `<a target="_blank">` nao navega, nao abre o aplicativo e
    /// nem reporta erro, porque sem WKUIDelegate nao ha janela nova para criar.
    /// Aqui a navegacao e cancelada e o endereco vai para o NSWorkspace, que
    /// escolhe o aplicativo: o navegador para `https`, o Kindle para `kindle`.
    ///
    /// Fica DENTRO da janela o que e a propria pagina: `file:` (o
    /// biblioteca.html do pacote), `about:` (as janelas de impressao) e os
    /// `blob:`/`data:` que as exportacoes usam — mandar esses para fora
    /// quebraria Exportar e Imprimir.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let esquema = url.scheme?.lowercased() else {
            decisionHandler(.allow); return
        }
        if url.isFileURL || ["about", "blob", "data"].contains(esquema) {
            decisionHandler(.allow); return
        }
        // Clique num link, ou link que pediu janela nova (targetFrame nil).
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate — os diálogos do JavaScript
//
// O WKWebView NAO tem diálogo nenhum por conta própria. `alert()`, `confirm()`
// e `prompt()` so existem se o app os desenhar; sem este delegate, `alert` e
// ignorado e `confirm` devolve FALSE imediatamente. Nada falha, nada avisa — a
// pagina simplesmente age como se o usuario tivesse dito "nao".
//
// Esta e a QUARTA vez que a mesma classe de defeito aparece neste app: antes
// foram `target="_blank"`, `window.print()` e `window.open`. Por isso existe
// agora o `bin/conferir-ponte.py`, que compara o que a pagina usa com o que
// cada hospedeiro implementa.

extension AppDelegate: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.beginSheetModal(for: janela) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancelar")
        a.beginSheetModal(for: janela) { resposta in
            completionHandler(resposta == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert()
        a.messageText = prompt
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancelar")
        let campo = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        campo.stringValue = defaultText ?? ""
        a.accessoryView = campo
        a.beginSheetModal(for: janela) { resposta in
            completionHandler(resposta == .alertFirstButtonReturn ? campo.stringValue : nil)
        }
    }
}

// MARK: - WKScriptMessageHandler — recebe TSV do HTML e grava no iCloud

// MARK: - "Selecionar pasta"
//
// As quatro operacoes que o fluxo da pagina usa. A pagina e a MESMA do
// Windows: quem decide os ramos e o `selecionarPasta()` do biblioteca.html, e
// aqui ficam so os quatro servicos que ele pede. Os nomes e o formato das
// respostas sao os mesmos dos comandos do Rust, de proposito -- se divergissem,
// o fluxo teria de saber em que aplicativo esta rodando.

extension AppDelegate {

    /// O painel de pastas do sistema, ja posicionado na pasta em uso.
    ///
    /// Assim o passo vira uma CONFIRMACAO em vez de uma procura, e o acerto
    /// automatico do iCloud nao se perde. Devolve "" quando se fecha sem
    /// escolher: cancelar nao e erro.
    func escolherPastaNoPainel() -> String {
        let painel = NSOpenPanel()
        painel.canChooseFiles = false
        painel.canChooseDirectories = true
        painel.allowsMultipleSelection = false
        painel.canCreateDirectories = true
        painel.directoryURL = pastaDeDados
        painel.message = "Escolha a pasta onde fica o seu biblioteca.txt"
        painel.prompt = "Selecionar"
        guard painel.runModal() == .OK, let url = painel.url else { return "" }
        return url.path
    }

    /// Passa a usar a pasta e rele tudo dela.
    func definirPasta(_ pasta: URL) -> String {
        UserDefaults.standard.set(pasta.path, forKey: Self.chaveDaPasta)
        recarregarDoICloud()
        return arquivoDaBiblioteca.path
    }

    /// Cria o biblioteca.txt na pasta e passa a usa-la.
    ///
    /// NAO SOBRESCREVE: se o arquivo apareceu entre o olhar e esta chamada,
    /// recusa com `ja_existe` e a pagina volta ao ramo "achei uma biblioteca".
    /// O iCloud baixa arquivo renomeando e trocando depois; sem esta checagem o
    /// aplicativo poderia zerar a biblioteca de alguem no intervalo.
    ///
    /// Escreve o arquivo ANTES de guardar a pasta: na ordem inversa, uma falha
    /// de escrita deixaria o aplicativo apontado para uma pasta sem biblioteca.
    func criarNaPasta(_ pasta: URL, conteudo: String) throws -> String {
        _ = try criarArquivoNaPasta(pasta, conteudo: conteudo)
        return definirPasta(pasta)
    }
}

// MARK: - As duas que mexem em ARQUIVO
//
// Fora do AppDelegate de proposito: sao as unicas partes do "Selecionar pasta"
// que podem PERDER dado, e aqui elas rodam nos testes (`swift test`) sem subir
// a aplicacao inteira -- sem janela, sem WKWebView e sem tocar no
// UserDefaults da maquina de quem roda os testes. Espelham `olhar` e
// `criar_arquivo_na_pasta` do Rust do Windows; se divergirem, o mesmo botao
// faria coisas diferentes nos dois aplicativos.

enum ErroDePasta: Error, Equatable { case mensagem(String) }

/// Olha a pasta ANTES de vincular: ha biblioteca.txt? da para ler? o que tem?
///
/// Devolve o CONTEUDO, nao uma contagem: quem conta os livros e a mesma
/// `parseTSV` da pagina que vai carrega-los. Dois leitores de TSV divergem --
/// e o numero que o usuario le na pergunta tem de ser o que ele vera na tela.
func olharAPasta(_ pasta: URL) -> [String: Any] {
    let fm = FileManager.default
    func resposta(_ tem: Bool, _ conteudo: String, _ erro: String) -> [String: Any] {
        ["nome": pasta.lastPathComponent, "caminho": pasta.path,
         "temArquivo": tem, "conteudo": conteudo, "erro": erro]
    }
    var ehPasta = ObjCBool(false)
    guard fm.fileExists(atPath: pasta.path, isDirectory: &ehPasta), ehPasta.boolValue else {
        return resposta(false, "", "A pasta não existe: \(pasta.path)")
    }
    let arquivo = pasta.appendingPathComponent("biblioteca.txt")
    // `fileExists` tambem e verdadeiro para um DIRETORIO chamado
    // biblioteca.txt. E de proposito: ha arquivo no caminho, so nao da para
    // ler -- e o certo entao e avisar, nunca criar por cima.
    guard fm.fileExists(atPath: arquivo.path) else { return resposta(false, "", "") }

    // No iCloud o arquivo pode existir so como marcador, com o conteudo ainda
    // na nuvem. Pedir o download e esperar um pouco e o que o
    // `carregarDoICloud` ja faz na abertura -- sem isto, escolher uma pasta do
    // iCloud recem-sincronizada cairia no ramo "nao consegui ler".
    if (try? arquivo.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
        .ubiquitousItemDownloadingStatus == .some(.notDownloaded) {
        try? fm.startDownloadingUbiquitousItem(at: arquivo)
    }
    var ultimoErro = ""
    for tentativa in 0..<3 {
        do {
            return resposta(true, try String(contentsOf: arquivo, encoding: .utf8), "")
        } catch {
            ultimoErro = error.localizedDescription
            Thread.sleep(forTimeInterval: 0.4 * Double(tentativa + 1))
        }
    }
    return resposta(true, "", ultimoErro)
}

/// Cria o biblioteca.txt na pasta e devolve o caminho dele.
///
/// NAO SOBRESCREVE: se o arquivo apareceu entre o olhar e esta chamada, recusa
/// com `ja_existe` e a pagina volta ao ramo "achei uma biblioteca". O iCloud
/// baixa arquivo renomeando e trocando depois; sem esta checagem o aplicativo
/// poderia zerar a biblioteca de alguem no intervalo.
func criarArquivoNaPasta(_ pasta: URL, conteudo: String) throws -> URL {
    let fm = FileManager.default
    var ehPasta = ObjCBool(false)
    guard fm.fileExists(atPath: pasta.path, isDirectory: &ehPasta), ehPasta.boolValue else {
        throw ErroDePasta.mensagem("A pasta não existe: \(pasta.path)")
    }
    let arquivo = pasta.appendingPathComponent("biblioteca.txt")
    if fm.fileExists(atPath: arquivo.path) { throw ErroDePasta.mensagem("ja_existe") }
    try conteudo.write(to: arquivo, atomically: true, encoding: .utf8)
    return arquivo
}

// MARK: - O canal que RESPONDE

extension AppDelegate: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let pedido = message.body as? [String: Any],
              let operacao = pedido["op"] as? String else {
            replyHandler(nil, "pedido sem operação"); return
        }
        let pasta: URL? = (pedido["caminho"] as? String).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        switch operacao {
        case "escolher":
            replyHandler(escolherPastaNoPainel(), nil)
        case "olhar":
            guard let pasta else { replyHandler(nil, "sem caminho"); return }
            replyHandler(olharAPasta(pasta), nil)
        case "definir":
            guard let pasta else { replyHandler(nil, "sem caminho"); return }
            replyHandler(definirPasta(pasta), nil)
        case "criar":
            guard let pasta else { replyHandler(nil, "sem caminho"); return }
            do {
                replyHandler(try criarNaPasta(pasta, conteudo: pedido["conteudo"] as? String ?? ""), nil)
            } catch ErroDePasta.mensagem(let m) {
                replyHandler(nil, m)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        default:
            replyHandler(nil, "operação desconhecida: \(operacao)")
        }
    }
}

extension AppDelegate: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        switch message.name {
        case "exportar":
            guard let conteudo = message.body as? String else { return }
            agendarGravacao(conteudo)
        case "fotos":
            guard let conteudo = message.body as? String else { return }
            agendarGravacaoDat(conteudo)
        case "backup":
            guard let sufixo = message.body as? String else { return }
            fazerBackup(sufixo)
        case "fotosRemovidas":
            guard let json = message.body as? String,
                  let dados = json.data(using: .utf8),
                  let ids = try? JSONSerialization.jsonObject(with: dados) as? [String]
            else { return }
            registrarRemocoes(ids)
        case "fotosReadicionadas":
            guard let json = message.body as? String,
                  let dados = json.data(using: .utf8),
                  let ids = try? JSONSerialization.jsonObject(with: dados) as? [String]
            else { return }
            cancelarRemocoes(ids)
        case "copiar":
            // `navigator.clipboard` nao existe numa pagina `file:` (nao e
            // contexto seguro), entao quem copia e o AppKit.
            guard let texto = message.body as? String, !texto.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(texto, forType: .string)
        case "imprimir":
            guard let html = message.body as? String else { return }
            impressor.imprimir(html)
        case "salvarArquivo":
            guard let json = message.body as? String,
                  let dados = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: String],
                  let nome = obj["nome"], let base64 = obj["base64"],
                  let conteudo = Data(base64Encoded: base64)
            else { return }
            salvarArquivoEscolhendoPasta(nome: nome, conteudo: conteudo)
        case "grupos":
            guard let json = message.body as? String else { return }
            gravarGrupos(json)
        case "kindleListar":
            responderKindleListar()
        case "kindleCapas":
            guard let json = message.body as? String else { return }
            responderKindleCapas(json)
        case "audibleListar":
            responderAudibleListar()
        case "recarregar":
            // Equivalente ao ⌘R do menu, acionável pelo botão da própria página —
            // assim o Mac e o Windows têm o mesmo controle no mesmo lugar.
            recarregarDoICloud()
        case "fechar":
            DispatchQueue.main.async { NSApp.terminate(nil) }
        default:
            break
        }
    }
}


// MARK: - Impressao
//
// O `window.print()` NAO existe dentro do WKWebView e o `window.open` devolve
// nulo sem WKUIDelegate: medido em 07/10/2026, os dois botoes de imprimir do app
// nao faziam nada, sem erro nenhum. A pagina manda o HTML pronto e quem imprime
// e o AppKit.

/// Guarda-se a si mesma ate a impressao terminar: um WKWebView fora de tela e
/// solto assim que a funcao retorna, e o didFinish nunca chegaria.
final class ImpressorDeHTML: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var enquantoImprime: ImpressorDeHTML?

    func imprimir(_ html: String) {
        let info = NSPrintInfo.shared
        let largura = info.paperSize.width - info.leftMargin - info.rightMargin
        let altura = info.paperSize.height - info.topMargin - info.bottomMargin
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: largura, height: altura))
        web.navigationDelegate = self
        self.web = web
        self.enquantoImprime = self
        web.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operacao = webView.printOperation(with: info)
        operacao.showsPrintPanel = true
        operacao.showsProgressPanel = true
        operacao.view?.frame = webView.frame
        if let janela = NSApp.mainWindow {
            operacao.runModal(for: janela, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operacao.run()
        }
        self.web = nil
        self.enquantoImprime = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.web = nil
        self.enquantoImprime = nil
    }
}
