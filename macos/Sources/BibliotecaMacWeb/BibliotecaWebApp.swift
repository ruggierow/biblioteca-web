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

        // Injeta __BIBLIOTECA_NATIVE__ antes do HTML executar qualquer script
        let flagNativa = WKUserScript(
            source: "window.__BIBLIOTECA_NATIVE__ = true;",
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
        let js = """
        (function() {
            try {
                var raw = localStorage.getItem("biblioteca-fotos");
                var f = raw ? JSON.parse(raw) : {};
                var keys = Object.keys(f);
                return JSON.stringify({ total: keys.length, dados: f });
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

        let js = """
        (function() {
            try {
                var novasFotos = JSON.parse(`\(escapado)`);
                var locais = {};
                try { locais = JSON.parse(localStorage.getItem("biblioteca-fotos")) || {}; } catch(e) {}
                var merged = Object.assign({}, locais, novasFotos);
                fotos = merged;
                localStorage.setItem("biblioteca-fotos", JSON.stringify(merged));
                if (typeof atualizarTudo === 'function') atualizarTudo();
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

    // MARK: - Utilitário

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
        case "fechar":
            DispatchQueue.main.async { NSApp.terminate(nil) }
        default:
            break
        }
    }
}
