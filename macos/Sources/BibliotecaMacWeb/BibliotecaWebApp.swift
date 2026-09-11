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
    private var gravarTimer: Timer?
    private var gravarDatTimer: Timer?

    // MARK: - Caminhos do iCloud

    private var iCloudURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Biblioteca/biblioteca.txt")
    }

    private var iCloudDatURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Biblioteca/biblioteca.dat")
    }

    // MARK: - Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()

        // Pontes nativas
        config.userContentController.add(self, name: "exportar")
        config.userContentController.add(self, name: "fotos")
        config.userContentController.add(self, name: "fechar")
        config.userContentController.add(self, name: "backup")
        config.userContentController.add(self, name: "recarregar")

        // Injeta __BIBLIOTECA_NATIVE__ e o caminho real do arquivo antes do HTML
        // executar qualquer script. O caminho aparece no banner de sincronização,
        // igual ao que o app do Windows mostra — ajuda a diagnosticar quando os
        // dois lados não estão apontando para o mesmo arquivo.
        let caminhoJS = Self.paraLiteralJS(iCloudURL.path)
        let flagNativa = WKUserScript(
            source: """
            window.__BIBLIOTECA_NATIVE__ = true;
            window.__BIBLIOTECA_CAMINHO__ = \(caminhoJS);
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(flagNativa)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

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
        let url = iCloudURL
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

    private func carregarFotosDoICloud() {
        let url = iCloudDatURL
        let fm = FileManager.default

        // Se biblioteca.dat ainda não existe, exporta o localStorage atual para criá-lo
        guard fm.fileExists(atPath: url.path) else {
            exportarLocalStorageParaICloud()
            return
        }

        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .some(.notDownloaded) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.carregarFotosDoICloud() }
            return
        }

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

    private func injetarFotos(_ json: String) {
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

    private func agendarGravacaoDat(_ json: String) {
        gravarDatTimer?.invalidate()
        gravarDatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.gravarDatNoICloud(json)
        }
    }

    private func gravarDatNoICloud(_ json: String) {
        let url = iCloudDatURL
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
        let url = iCloudURL
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
        let itemRecarregar = NSMenuItem(title: "Recarregar do iCloud",
                                        action: #selector(recarregarDoICloud),
                                        keyEquivalent: "r")
        itemRecarregar.target = self
        arquivoMenu.addItem(itemRecarregar)

        let itemExportarFotos = NSMenuItem(title: "Exportar Fotos para iCloud",
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
        let origem = iCloudURL
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
}

// MARK: - WKScriptMessageHandler — recebe TSV do HTML e grava no iCloud

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
