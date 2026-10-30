const { test, expect } = require("@playwright/test");
const { livro, abrir, livrosGravados, responderDialogos } = require("../ajuda");

/**
 * "Atualizar do Kindle" — um sentido so.
 *
 * O lado NATIVO (Mac) le o banco do Kindle; conferi em 29/10/2026 que o leitor
 * em Swift devolve os 187 registros IDENTICOS ao de `bin/conciliar-kindle.py`,
 * campo a campo. O que estes casos trancam e a outra metade, a que mora na
 * pagina: decidir o que e NOVO e dar forma a linha.
 *
 * A ponte e simulada aqui de proposito. No Mac de verdade ela devolve a
 * biblioteca do Kindle; o teste devolve uma lista escolhida, e assim da para
 * exercitar o livro novo mesmo quando a biblioteca real nao tem nenhum (hoje
 * os 116 ja estao todos na base).
 */

const COMENTARIO = (asin) =>
  `Ler: https://read.amazon.com/?asin=${asin} | Kindle: kindle://book?action=open&asin=${asin}`;

/** Abre a pagina fingindo ser o app do Mac, com a biblioteca do Kindle dada. */
async function abrirComKindle(page, livros, doKindle) {
  await page.addInitScript((doKindle) => {
    // SO a bandeira do Kindle. Pondo __BIBLIOTECA_NATIVE__ a pagina passa a
    // esperar o lado nativo injetar a base, que no teste nunca vem, e ela fica
    // presa na tela de carregamento. O botao do Kindle nao depende dela.
    window.__BIBLIOTECA_KINDLE__ = true;
    window.__PEDIDOS__ = [];
    window.webkit = {
      messageHandlers: new Proxy({}, {
        get: (_, canal) => ({
          postMessage: (corpo) => {
            window.__PEDIDOS__.push({ canal, corpo });
            if (canal === "kindleListar") {
              setTimeout(() => window.kindleRecebeLista({ ok: true, livros: doKindle }), 0);
            }
          },
        }),
      }),
    };
  }, doKindle);
  return abrir(page, livros);
}

const UM_NOVO = [{
  asin: "B0NOVO00001", titulo: "O Nome do Vento (Portuguese Edition)",
  autor: "Rothfuss, Patrick", ano: "2009", compra: "2026-10-28",
}];

test.describe("Atualizar do Kindle", () => {
  test("o botao NAO aparece onde nao ha Kindle", async ({ page }) => {
    await abrir(page, []);          // navegador comum: sem a bandeira nativa
    await expect(page.locator("#btn-kindle")).toBeHidden();
  });

  test("o botao aparece quando o lado nativo diz que ha Kindle", async ({ page }) => {
    await abrirComKindle(page, [], []);
    await expect(page.locator("#btn-kindle")).toBeVisible();
  });

  test("livro novo entra com local Kindle, os dois links e o titulo LIMPO", async ({ page }) => {
    await abrirComKindle(page, [], UM_NOVO);
    await page.click("#btn-kindle");
    await expect(page.locator("#modal-kindle")).toBeVisible();
    await page.click("#btn-kindle-confirmar");

    const base = await livrosGravados(page);
    expect(base).toHaveLength(1);
    const l = base[0];
    expect(l.titulo).toBe("O Nome do Vento");        // sem "(Portuguese Edition)"
    expect(l.autores).toEqual(["Patrick Rothfuss"]); // e nao "Rothfuss, Patrick"
    expect(l.local).toBe("Kindle");
    expect(l.temas).toEqual([]);
    expect(l.comentarios).toBe(COMENTARIO("B0NOVO00001"));
    expect(l.ano).toBe(2009);
  });

  test("o que JA esta na base pelo ASIN nao reaparece", async ({ page }) => {
    await abrirComKindle(page, [
      livro("O Nome do Vento", { local: "Kindle", comentarios: COMENTARIO("B0NOVO00001") }),
    ], UM_NOVO);
    await page.click("#btn-kindle");
    await expect(page.locator("#kindle-resumo")).toContainText("todos ja estao aqui");
    await expect(page.locator("#btn-kindle-confirmar")).toBeHidden();
    expect(await livrosGravados(page)).toHaveLength(1);
  });

  test("a edicao Kindle de um livro que voce tem em PAPEL vira linha nova, com aviso", async ({ page }) => {
    await abrirComKindle(page, [
      livro("O Nome do Vento", { autores: ["Patrick Rothfuss"], local: "Estante 3" }),
    ], UM_NOVO);
    await page.click("#btn-kindle");
    // O aviso existe para voce conferir que nao e engano...
    await expect(page.locator("#kindle-lista")).toContainText("Estante 3");
    responderDialogos(page, true);
    await page.click("#btn-kindle-confirmar");
    // ...mas a linha entra: sao duas edicoes da mesma obra.
    const base = await livrosGravados(page);
    expect(base).toHaveLength(2);
    expect(base.map(l => l.local).sort()).toEqual(["Estante 3", "Kindle"]);
  });

  test("desmarcar deixa o livro de fora", async ({ page }) => {
    await abrirComKindle(page, [], UM_NOVO);
    await page.click("#btn-kindle");
    await page.uncheck(".kindle-item");
    await page.click("#btn-kindle-confirmar");
    expect(await livrosGravados(page)).toHaveLength(0);
  });

  // O sentido unico, que e a regra que o usuario pediu: nada sai, nada muda.
  test("nunca remove nem reescreve o que ja esta na base", async ({ page }) => {
    const antes = [
      livro("Livro de Papel", { local: "Estante 1", comentarios: "anotacao minha" }),
      livro("Outro do Kindle", { local: "Kindle", comentarios: COMENTARIO("B0VELHO0001") }),
    ];
    // A biblioteca do Kindle NAO tem "Outro do Kindle" nem o de papel.
    await abrirComKindle(page, antes, UM_NOVO);
    await page.click("#btn-kindle");
    await page.click("#btn-kindle-confirmar");
    const base = await livrosGravados(page);
    expect(base).toHaveLength(3);
    const papel = base.find(l => l.titulo === "Livro de Papel");
    expect(papel.comentarios).toBe("anotacao minha");
    expect(papel.local).toBe("Estante 1");
    expect(base.find(l => l.titulo === "Outro do Kindle")).toBeTruthy();
  });

  // O leitor da pagina DERRUBA linha com ano vazio (parseInt -> NaN -> continue).
  // Sem o valor de reserva, um livro do Kindle sem data de publicacao sumiria
  // na proxima leitura, em silencio.
  test("livro do Kindle SEM ano sobrevive a ida e volta pelo arquivo", async ({ page }) => {
    await abrirComKindle(page, [], [{ ...UM_NOVO[0], ano: "" }]);
    await page.click("#btn-kindle");
    await page.click("#btn-kindle-confirmar");
    const devolta = await page.evaluate(() => parseTSV(serializarTSV()));
    expect(devolta).toHaveLength(1);
    expect(Number.isNaN(devolta[0].ano)).toBe(false);
  });

  test("pede as capas SO dos livros confirmados", async ({ page }) => {
    await abrirComKindle(page, [], [
      UM_NOVO[0],
      { asin: "B0NOVO00002", titulo: "Segundo Livro", autor: "Souza, Ana", ano: "2020", compra: "2026-10-27" },
    ]);
    await page.click("#btn-kindle");
    await page.uncheck(".kindle-item[data-i='1']");
    await page.click("#btn-kindle-confirmar");
    const pedido = await page.evaluate(() =>
      window.__PEDIDOS__.filter(p => p.canal === "kindleCapas").pop());
    expect(JSON.parse(pedido.corpo)).toEqual(["B0NOVO00001"]);
  });

  test("a capa recebida nao sobrescreve capa que ja existe", async ({ page }) => {
    await abrirComKindle(page, [], UM_NOVO);
    await page.click("#btn-kindle");
    await page.click("#btn-kindle-confirmar");
    const id = (await livrosGravados(page))[0].id;
    await page.evaluate((id) => { fotos[id] = "data:image/png;base64,JAMUDA"; }, id);
    await page.evaluate((id) => window.kindleRecebeCapas({ capas: { B0NOVO00001: "data:image/jpeg;base64,NOVA" } }), id);
    const guardada = await page.evaluate((id) => fotos[id], id);
    expect(guardada).toBe("data:image/png;base64,JAMUDA");
  });

  // Tema e pais sao da OBRA, nao da edicao. Em 30/10/2026 o "Judas" do Kindle
  // entrou sem os dois, tendo ambos na linha do impresso: a regra existia no
  // conciliador em Python e NAO na pagina.
  test("a edicao Kindle herda tema e pais da obra que voce ja tem", async ({ page }) => {
    await abrirComKindle(page, [
      livro("O Nome do Vento", {
        autores: ["Patrick Rothfuss"], local: "Estante 3",
        temas: ["Fantasia"], pais: "US",
      }),
    ], UM_NOVO);
    await page.click("#btn-kindle");
    responderDialogos(page, true);
    await page.click("#btn-kindle-confirmar");

    const base = await livrosGravados(page);
    const doKindle = base.find(l => l.local === "Kindle");
    expect(doKindle.temas).toEqual(["Fantasia"]);
    expect(doKindle.pais).toBe("US");
    // E o impresso continua intocado — o sentido e unico.
    expect(base.find(l => l.local === "Estante 3").temas).toEqual(["Fantasia"]);
  });

  test("livro que a base NAO tem continua entrando sem tema e sem pais", async ({ page }) => {
    await abrirComKindle(page, [], UM_NOVO);
    await page.click("#btn-kindle");
    await page.click("#btn-kindle-confirmar");
    const l = (await livrosGravados(page))[0];
    expect(l.temas).toEqual([]);
    expect(l.pais || "").toBe("");
  });
});
