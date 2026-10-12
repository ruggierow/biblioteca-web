// @ts-check
const { defineConfig } = require("@playwright/test");

/**
 * Os testes rodam sobre a MESMA pagina que o Mac e o Windows embarcam —
 * `motor-web/biblioteca.html` —, servida por HTTP. Nao e uma copia nem um
 * arremedo: e o arquivo que vai nos dois aplicativos.
 *
 * O QUE ESTES TESTES NAO PEGAM, e e bom estar escrito: o que depende do
 * HOSPEDEIRO. Aqui `confirm()` funciona, `window.print()` existe e
 * `target="_blank"` abre — no WKWebView, nenhum dos tres. Essa familia de
 * defeito e do `bin/conferir-ponte.py`, nao daqui. Os dois juntos cobrem; cada
 * um sozinho engana.
 */
module.exports = defineConfig({
  testDir: "./casos",
  timeout: 20000,
  fullyParallel: true,
  reporter: [["list"]],
  use: {
    baseURL: "http://127.0.0.1:8731",
    actionTimeout: 5000,
  },
  webServer: {
    command: "python3 -m http.server 8731 --bind 127.0.0.1 --directory ..",
    url: "http://127.0.0.1:8731/biblioteca.html",
    reuseExistingServer: true,
    timeout: 20000,
  },
});
